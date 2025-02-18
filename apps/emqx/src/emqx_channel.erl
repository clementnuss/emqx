%%--------------------------------------------------------------------
%% Copyright (c) 2019-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

%% MQTT Channel
-module(emqx_channel).

-include("emqx.hrl").
-include("emqx_channel.hrl").
-include("emqx_mqtt.hrl").
-include("emqx_access_control.hrl").
-include("logger.hrl").
-include("types.hrl").

-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-ifdef(TEST).
-compile(export_all).
-compile(nowarn_export_all).
-endif.

-export([
    info/1,
    info/2,
    get_mqtt_conf/2,
    get_mqtt_conf/3,
    set_conn_state/2,
    stats/1,
    caps/1
]).

-export([
    init/2,
    handle_in/2,
    handle_deliver/2,
    handle_out/3,
    handle_timeout/3,
    handle_call/2,
    handle_info/2,
    terminate/2
]).

%% Export for emqx_sn
-export([
    do_deliver/2,
    ensure_keepalive/2,
    clear_keepalive/1
]).

%% Export for emqx_channel implementations
-export([
    maybe_nack/1
]).

%% Exports for CT
-export([set_field/3]).

-import(
    emqx_utils,
    [
        run_fold/3,
        pipeline/3,
        maybe_apply/2
    ]
).

-export_type([channel/0, opts/0, conn_state/0, reply/0, replies/0]).

-record(channel, {
    %% MQTT ConnInfo
    conninfo :: emqx_types:conninfo(),
    %% MQTT ClientInfo
    clientinfo :: emqx_types:clientinfo(),
    %% MQTT Session
    session :: maybe(emqx_session:t()),
    %% Keepalive
    keepalive :: maybe(emqx_keepalive:keepalive()),
    %% MQTT Will Msg
    will_msg :: maybe(emqx_types:message()),
    %% MQTT Topic Aliases
    topic_aliases :: emqx_types:topic_aliases(),
    %% MQTT Topic Alias Maximum
    alias_maximum :: maybe(map()),
    %% Authentication Data Cache
    auth_cache :: maybe(map()),
    %% Quota checkers
    quota :: emqx_limiter_container:container(),
    %% Timers
    timers :: #{atom() => disabled | maybe(reference())},
    %% Conn State
    conn_state :: conn_state(),
    %% Takeover
    takeover :: boolean(),
    %% Resume
    resuming :: false | _ReplayContext,
    %% Pending delivers when takeovering
    pendings :: list()
}).

-type channel() :: #channel{}.

-type opts() :: #{
    zone := atom(),
    listener := {Type :: atom(), Name :: atom()},
    atom() => term()
}.

-type conn_state() :: idle | connecting | connected | reauthenticating | disconnected.

-type reply() ::
    {outgoing, emqx_types:packet()}
    | {outgoing, [emqx_types:packet()]}
    | {connack, emqx_types:packet()}
    | {event, conn_state() | updated}
    | {close, Reason :: atom()}.

-type replies() :: emqx_types:packet() | reply() | [reply()].

-define(IS_MQTT_V5, #channel{conninfo = #{proto_ver := ?MQTT_PROTO_V5}}).

-define(IS_COMMON_SESSION_TIMER(N),
    ((N == retry_delivery) orelse (N == expire_awaiting_rel))
).

-define(LIMITER_ROUTING, message_routing).

-dialyzer({no_match, [shutdown/4, ensure_timer/2, interval/2]}).

%%--------------------------------------------------------------------
%% Info, Attrs and Caps
%%--------------------------------------------------------------------

%% @doc Get infos of the channel.
-spec info(channel()) -> emqx_types:infos().
info(Channel) ->
    maps:from_list(info(?INFO_KEYS, Channel)).

-spec info(list(atom()) | atom() | tuple(), channel()) -> term().
info(Keys, Channel) when is_list(Keys) ->
    [{Key, info(Key, Channel)} || Key <- Keys];
info(conninfo, #channel{conninfo = ConnInfo}) ->
    ConnInfo;
info(socktype, #channel{conninfo = ConnInfo}) ->
    maps:get(socktype, ConnInfo, undefined);
info(peername, #channel{conninfo = ConnInfo}) ->
    maps:get(peername, ConnInfo, undefined);
info(sockname, #channel{conninfo = ConnInfo}) ->
    maps:get(sockname, ConnInfo, undefined);
info(proto_name, #channel{conninfo = ConnInfo}) ->
    maps:get(proto_name, ConnInfo, undefined);
info(proto_ver, #channel{conninfo = ConnInfo}) ->
    maps:get(proto_ver, ConnInfo, undefined);
info(connected_at, #channel{conninfo = ConnInfo}) ->
    maps:get(connected_at, ConnInfo, undefined);
info(clientinfo, #channel{clientinfo = ClientInfo}) ->
    ClientInfo;
info(zone, #channel{clientinfo = ClientInfo}) ->
    maps:get(zone, ClientInfo);
info(listener, #channel{clientinfo = ClientInfo}) ->
    maps:get(listener, ClientInfo);
info(clientid, #channel{clientinfo = ClientInfo}) ->
    maps:get(clientid, ClientInfo, undefined);
info(username, #channel{clientinfo = ClientInfo}) ->
    maps:get(username, ClientInfo, undefined);
info(session, #channel{session = Session}) ->
    maybe_apply(fun emqx_session:info/1, Session);
info({session, Info}, #channel{session = Session}) ->
    maybe_apply(fun(S) -> emqx_session:info(Info, S) end, Session);
info(conn_state, #channel{conn_state = ConnState}) ->
    ConnState;
info(keepalive, #channel{keepalive = Keepalive}) ->
    maybe_apply(fun emqx_keepalive:info/1, Keepalive);
info(will_msg, #channel{will_msg = undefined}) ->
    undefined;
info(will_msg, #channel{will_msg = WillMsg}) ->
    emqx_message:to_map(WillMsg);
info(topic_aliases, #channel{topic_aliases = Aliases}) ->
    Aliases;
info(alias_maximum, #channel{alias_maximum = Limits}) ->
    Limits;
info(timers, #channel{timers = Timers}) ->
    Timers.

set_conn_state(ConnState, Channel) ->
    Channel#channel{conn_state = ConnState}.

-spec stats(channel()) -> emqx_types:stats().
stats(#channel{session = undefined}) ->
    emqx_pd:get_counters(?CHANNEL_METRICS);
stats(#channel{session = Session}) ->
    lists:append(emqx_session:stats(Session), emqx_pd:get_counters(?CHANNEL_METRICS)).

-spec caps(channel()) -> emqx_types:caps().
caps(#channel{clientinfo = #{zone := Zone}}) ->
    emqx_mqtt_caps:get_caps(Zone).

%%--------------------------------------------------------------------
%% Init the channel
%%--------------------------------------------------------------------

-spec init(emqx_types:conninfo(), opts()) -> channel().
init(
    ConnInfo = #{
        peername := {PeerHost, PeerPort},
        sockname := {_Host, SockPort}
    },
    #{
        zone := Zone,
        limiter := LimiterCfg,
        listener := {Type, Listener}
    } = Opts
) ->
    Peercert = maps:get(peercert, ConnInfo, undefined),
    Protocol = maps:get(protocol, ConnInfo, mqtt),
    MountPoint =
        case emqx_config:get_listener_conf(Type, Listener, [mountpoint]) of
            <<>> -> undefined;
            MP -> MP
        end,
    ListenerId = emqx_listeners:listener_id(Type, Listener),
    ClientInfo = set_peercert_infos(
        Peercert,
        #{
            zone => Zone,
            listener => ListenerId,
            protocol => Protocol,
            peerhost => PeerHost,
            peerport => PeerPort,
            sockport => SockPort,
            clientid => undefined,
            username => undefined,
            mountpoint => MountPoint,
            is_bridge => false,
            is_superuser => false,
            enable_authn => maps:get(enable_authn, Opts, true)
        },
        Zone
    ),
    {NClientInfo, NConnInfo} = take_ws_cookie(ClientInfo, ConnInfo),
    #channel{
        conninfo = NConnInfo,
        clientinfo = NClientInfo,
        topic_aliases = #{
            inbound => #{},
            outbound => #{}
        },
        auth_cache = #{},
        quota = emqx_limiter_container:get_limiter_by_types(
            ListenerId, [?LIMITER_ROUTING], LimiterCfg
        ),
        timers = #{},
        conn_state = idle,
        takeover = false,
        resuming = false,
        pendings = []
    }.

set_peercert_infos(NoSSL, ClientInfo, _) when
    NoSSL =:= nossl;
    NoSSL =:= undefined
->
    ClientInfo#{username => undefined};
set_peercert_infos(Peercert, ClientInfo, Zone) ->
    {DN, CN} = {esockd_peercert:subject(Peercert), esockd_peercert:common_name(Peercert)},
    PeercetAs = fun(Key) ->
        case get_mqtt_conf(Zone, Key) of
            cn -> CN;
            dn -> DN;
            crt -> Peercert;
            pem when is_binary(Peercert) -> base64:encode(Peercert);
            md5 when is_binary(Peercert) -> emqx_passwd:hash_data(md5, Peercert);
            _ -> undefined
        end
    end,
    Username = PeercetAs(peer_cert_as_username),
    ClientId = PeercetAs(peer_cert_as_clientid),
    ClientInfo#{username => Username, clientid => ClientId, dn => DN, cn => CN}.

take_ws_cookie(ClientInfo, ConnInfo) ->
    case maps:take(ws_cookie, ConnInfo) of
        {WsCookie, NConnInfo} ->
            {ClientInfo#{ws_cookie => WsCookie}, NConnInfo};
        _ ->
            {ClientInfo, ConnInfo}
    end.

%%--------------------------------------------------------------------
%% Handle incoming packet
%%--------------------------------------------------------------------

-spec handle_in(emqx_types:packet(), channel()) ->
    {ok, channel()}
    | {ok, replies(), channel()}
    | {shutdown, Reason :: term(), channel()}
    | {shutdown, Reason :: term(), replies(), channel()}.
handle_in(?CONNECT_PACKET(), Channel = #channel{conn_state = ConnState}) when
    ConnState =:= connected orelse ConnState =:= reauthenticating
->
    handle_out(disconnect, ?RC_PROTOCOL_ERROR, Channel);
handle_in(?CONNECT_PACKET(), Channel = #channel{conn_state = connecting}) ->
    handle_out(connack, ?RC_PROTOCOL_ERROR, Channel);
handle_in(?CONNECT_PACKET(ConnPkt) = Packet, Channel) ->
    case
        pipeline(
            [
                fun overload_protection/2,
                fun enrich_conninfo/2,
                fun run_conn_hooks/2,
                fun check_connect/2,
                fun enrich_client/2,
                fun set_log_meta/2,
                fun check_banned/2,
                fun count_flapping_event/2
            ],
            ConnPkt,
            Channel#channel{conn_state = connecting}
        )
    of
        {ok, NConnPkt, NChannel = #channel{clientinfo = ClientInfo}} ->
            ?TRACE("MQTT", "mqtt_packet_received", #{packet => Packet}),
            NChannel1 = NChannel#channel{
                alias_maximum = init_alias_maximum(NConnPkt, ClientInfo)
            },
            case authenticate(?CONNECT_PACKET(NConnPkt), NChannel1) of
                {ok, Properties, NChannel2} ->
                    %% only store will_msg after successful authn
                    %% fix for: https://github.com/emqx/emqx/issues/8886
                    NChannel3 = NChannel2#channel{will_msg = emqx_packet:will_msg(NConnPkt)},
                    process_connect(Properties, NChannel3);
                {continue, Properties, NChannel2} ->
                    handle_out(auth, {?RC_CONTINUE_AUTHENTICATION, Properties}, NChannel2);
                {error, ReasonCode} ->
                    handle_out(connack, ReasonCode, NChannel1)
            end;
        {error, ReasonCode, NChannel} ->
            handle_out(connack, ReasonCode, NChannel)
    end;
handle_in(
    Packet = ?AUTH_PACKET(ReasonCode, _Properties),
    Channel = #channel{conn_state = ConnState}
) ->
    try
        case {ReasonCode, ConnState} of
            {?RC_CONTINUE_AUTHENTICATION, connecting} -> ok;
            {?RC_CONTINUE_AUTHENTICATION, reauthenticating} -> ok;
            {?RC_RE_AUTHENTICATE, connected} -> ok;
            _ -> error(protocol_error)
        end,
        case authenticate(Packet, Channel) of
            {ok, NProperties, NChannel} ->
                case ConnState of
                    connecting ->
                        process_connect(NProperties, NChannel);
                    _ ->
                        handle_out(
                            auth,
                            {?RC_SUCCESS, NProperties},
                            NChannel#channel{conn_state = connected}
                        )
                end;
            {continue, NProperties, NChannel} ->
                handle_out(
                    auth,
                    {?RC_CONTINUE_AUTHENTICATION, NProperties},
                    NChannel#channel{conn_state = reauthenticating}
                );
            {error, NReasonCode} ->
                case ConnState of
                    connecting ->
                        handle_out(connack, NReasonCode, Channel);
                    _ ->
                        handle_out(disconnect, NReasonCode, Channel)
                end
        end
    catch
        _Class:_Reason ->
            case ConnState of
                connecting ->
                    handle_out(connack, ?RC_PROTOCOL_ERROR, Channel);
                _ ->
                    handle_out(disconnect, ?RC_PROTOCOL_ERROR, Channel)
            end
    end;
handle_in(?PACKET(_), Channel = #channel{conn_state = ConnState}) when
    ConnState =/= connected andalso ConnState =/= reauthenticating
->
    handle_out(disconnect, ?RC_PROTOCOL_ERROR, Channel);
handle_in(Packet = ?PUBLISH_PACKET(_QoS), Channel) ->
    case emqx_packet:check(Packet) of
        ok ->
            emqx_external_trace:trace_process_publish(
                Packet,
                %% More info can be added in future, but for now only clientid is used
                trace_info(Channel),
                fun(PacketWithTrace) -> process_publish(PacketWithTrace, Channel) end
            );
        {error, ReasonCode} ->
            handle_out(disconnect, ReasonCode, Channel)
    end;
handle_in(
    ?PUBACK_PACKET(PacketId, _ReasonCode, Properties),
    Channel =
        #channel{clientinfo = ClientInfo, session = Session}
) ->
    case emqx_session:puback(ClientInfo, PacketId, Session) of
        {ok, Msg, [], NSession} ->
            ok = after_message_acked(ClientInfo, Msg, Properties),
            {ok, Channel#channel{session = NSession}};
        {ok, Msg, Publishes, NSession} ->
            ok = after_message_acked(ClientInfo, Msg, Properties),
            handle_out(publish, Publishes, Channel#channel{session = NSession});
        {error, ?RC_PACKET_IDENTIFIER_IN_USE} ->
            ?SLOG(warning, #{msg => "puback_packetId_inuse", packetId => PacketId}),
            ok = emqx_metrics:inc('packets.puback.inuse'),
            {ok, Channel};
        {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND} ->
            ?SLOG(warning, #{msg => "puback_packetId_not_found", packetId => PacketId}),
            ok = emqx_metrics:inc('packets.puback.missed'),
            {ok, Channel}
    end;
handle_in(
    %% TODO: Why discard the Reason Code?
    ?PUBREC_PACKET(PacketId, _ReasonCode, Properties),
    Channel =
        #channel{clientinfo = ClientInfo, session = Session}
) ->
    case emqx_session:pubrec(ClientInfo, PacketId, Session) of
        {ok, Msg, NSession} ->
            ok = after_message_acked(ClientInfo, Msg, Properties),
            NChannel = Channel#channel{session = NSession},
            handle_out(pubrel, {PacketId, ?RC_SUCCESS}, NChannel);
        {error, RC = ?RC_PACKET_IDENTIFIER_IN_USE} ->
            ?SLOG(warning, #{msg => "pubrec_packetId_inuse", packetId => PacketId}),
            ok = emqx_metrics:inc('packets.pubrec.inuse'),
            handle_out(pubrel, {PacketId, RC}, Channel);
        {error, RC = ?RC_PACKET_IDENTIFIER_NOT_FOUND} ->
            ?SLOG(warning, #{msg => "pubrec_packetId_not_found", packetId => PacketId}),
            ok = emqx_metrics:inc('packets.pubrec.missed'),
            handle_out(pubrel, {PacketId, RC}, Channel)
    end;
handle_in(
    ?PUBREL_PACKET(PacketId, _ReasonCode),
    Channel = #channel{
        clientinfo = ClientInfo,
        session = Session
    }
) ->
    case emqx_session:pubrel(ClientInfo, PacketId, Session) of
        {ok, NSession} ->
            NChannel = Channel#channel{session = NSession},
            handle_out(pubcomp, {PacketId, ?RC_SUCCESS}, NChannel);
        {error, RC = ?RC_PACKET_IDENTIFIER_NOT_FOUND} ->
            ?SLOG(warning, #{msg => "pubrel_packetId_not_found", packetId => PacketId}),
            ok = emqx_metrics:inc('packets.pubrel.missed'),
            handle_out(pubcomp, {PacketId, RC}, Channel)
    end;
handle_in(
    ?PUBCOMP_PACKET(PacketId, _ReasonCode),
    Channel = #channel{
        clientinfo = ClientInfo, session = Session
    }
) ->
    case emqx_session:pubcomp(ClientInfo, PacketId, Session) of
        {ok, [], NSession} ->
            {ok, Channel#channel{session = NSession}};
        {ok, Publishes, NSession} ->
            handle_out(publish, Publishes, Channel#channel{session = NSession});
        {error, ?RC_PACKET_IDENTIFIER_IN_USE} ->
            ok = emqx_metrics:inc('packets.pubcomp.inuse'),
            {ok, Channel};
        {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND} ->
            ?SLOG(warning, #{msg => "pubcomp_packetId_not_found", packetId => PacketId}),
            ok = emqx_metrics:inc('packets.pubcomp.missed'),
            {ok, Channel}
    end;
handle_in(SubPkt = ?SUBSCRIBE_PACKET(PacketId, _Properties, _TopicFilters0), Channel0) ->
    Pipe = pipeline(
        [
            fun check_subscribe/2,
            fun enrich_subscribe/2,
            %% TODO && FIXME (EMQX-10786): mount topic before authz check.
            fun check_sub_authzs/2,
            fun check_sub_caps/2
        ],
        SubPkt,
        Channel0
    ),
    case Pipe of
        {ok, NPkt = ?SUBSCRIBE_PACKET(_PacketId, TFChecked), Channel} ->
            {TFSubedWithNRC, NChannel} = process_subscribe(run_sub_hooks(NPkt, Channel), Channel),
            ReasonCodes = gen_reason_codes(TFChecked, TFSubedWithNRC),
            handle_out(suback, {PacketId, ReasonCodes}, NChannel);
        {error, {disconnect, RC}, Channel} ->
            %% funcs in pipeline always cause action: `disconnect`
            %% And Only one ReasonCode in DISCONNECT packet
            handle_out(disconnect, RC, Channel)
    end;
handle_in(
    Packet = ?UNSUBSCRIBE_PACKET(PacketId, Properties, TopicFilters),
    Channel = #channel{clientinfo = ClientInfo}
) ->
    case emqx_packet:check(Packet) of
        ok ->
            TopicFilters1 = run_hooks(
                'client.unsubscribe',
                [ClientInfo, Properties],
                parse_raw_topic_filters(TopicFilters)
            ),
            {ReasonCodes, NChannel} = process_unsubscribe(TopicFilters1, Properties, Channel),
            handle_out(unsuback, {PacketId, ReasonCodes}, NChannel);
        {error, ReasonCode} ->
            handle_out(disconnect, ReasonCode, Channel)
    end;
handle_in(?PACKET(?PINGREQ), Channel) ->
    {ok, ?PACKET(?PINGRESP), Channel};
handle_in(
    ?DISCONNECT_PACKET(ReasonCode, Properties),
    Channel = #channel{conninfo = ConnInfo}
) ->
    NConnInfo = ConnInfo#{disconn_props => Properties},
    NChannel = maybe_clean_will_msg(ReasonCode, Channel#channel{conninfo = NConnInfo}),
    process_disconnect(ReasonCode, Properties, NChannel);
handle_in(?AUTH_PACKET(), Channel) ->
    handle_out(disconnect, ?RC_IMPLEMENTATION_SPECIFIC_ERROR, Channel);
handle_in({frame_error, Reason}, Channel = #channel{conn_state = idle}) ->
    shutdown(shutdown_count(frame_error, Reason), Channel);
handle_in({frame_error, frame_too_large}, Channel = #channel{conn_state = connecting}) ->
    shutdown(
        shutdown_count(frame_error, frame_too_large), ?CONNACK_PACKET(?RC_PACKET_TOO_LARGE), Channel
    );
handle_in({frame_error, Reason}, Channel = #channel{conn_state = connecting}) ->
    shutdown(shutdown_count(frame_error, Reason), ?CONNACK_PACKET(?RC_MALFORMED_PACKET), Channel);
handle_in({frame_error, frame_too_large}, Channel = #channel{conn_state = ConnState}) when
    ConnState =:= connected orelse ConnState =:= reauthenticating
->
    handle_out(disconnect, {?RC_PACKET_TOO_LARGE, frame_too_large}, Channel);
handle_in({frame_error, Reason}, Channel = #channel{conn_state = ConnState}) when
    ConnState =:= connected orelse ConnState =:= reauthenticating
->
    handle_out(disconnect, {?RC_MALFORMED_PACKET, Reason}, Channel);
handle_in({frame_error, Reason}, Channel = #channel{conn_state = disconnected}) ->
    ?SLOG(error, #{msg => "malformed_mqtt_message", reason => Reason}),
    {ok, Channel};
handle_in(Packet, Channel) ->
    ?SLOG(error, #{msg => "disconnecting_due_to_unexpected_message", packet => Packet}),
    handle_out(disconnect, ?RC_PROTOCOL_ERROR, Channel).

%%--------------------------------------------------------------------
%% Process Connect
%%--------------------------------------------------------------------

process_connect(
    AckProps,
    Channel = #channel{
        conninfo = ConnInfo,
        clientinfo = ClientInfo
    }
) ->
    #{clean_start := CleanStart} = ConnInfo,
    case emqx_cm:open_session(CleanStart, ClientInfo, ConnInfo) of
        {ok, #{session := Session, present := false}} ->
            NChannel = Channel#channel{session = Session},
            handle_out(connack, {?RC_SUCCESS, sp(false), AckProps}, ensure_connected(NChannel));
        {ok, #{session := Session, present := true, replay := ReplayContext}} ->
            NChannel = Channel#channel{
                session = Session,
                resuming = ReplayContext
            },
            handle_out(connack, {?RC_SUCCESS, sp(true), AckProps}, ensure_connected(NChannel));
        {error, client_id_unavailable} ->
            handle_out(connack, ?RC_CLIENT_IDENTIFIER_NOT_VALID, Channel);
        {error, Reason} ->
            ?SLOG(error, #{msg => "failed_to_open_session", reason => Reason}),
            handle_out(connack, ?RC_UNSPECIFIED_ERROR, Channel)
    end.

%%--------------------------------------------------------------------
%% Process Publish
%%--------------------------------------------------------------------

process_publish(Packet = ?PUBLISH_PACKET(QoS, Topic, PacketId), Channel) ->
    case
        pipeline(
            [
                fun check_quota_exceeded/2,
                fun process_alias/2,
                fun check_pub_alias/2,
                fun check_pub_authz/2,
                fun check_pub_caps/2
            ],
            Packet,
            Channel
        )
    of
        {ok, NPacket, NChannel} ->
            Msg = packet_to_message(NPacket, NChannel),
            do_publish(PacketId, Msg, NChannel);
        {error, Rc = ?RC_NOT_AUTHORIZED, NChannel} ->
            ?SLOG(
                warning,
                #{
                    msg => "cannot_publish_to_topic",
                    reason => emqx_reason_codes:name(Rc)
                },
                #{topic => Topic}
            ),
            case emqx:get_config([authorization, deny_action], ignore) of
                ignore ->
                    case QoS of
                        ?QOS_0 -> {ok, NChannel};
                        ?QOS_1 -> handle_out(puback, {PacketId, Rc}, NChannel);
                        ?QOS_2 -> handle_out(pubrec, {PacketId, Rc}, NChannel)
                    end;
                disconnect ->
                    handle_out(disconnect, Rc, NChannel)
            end;
        {error, Rc = ?RC_QUOTA_EXCEEDED, NChannel} ->
            ?SLOG(
                warning,
                #{
                    msg => "cannot_publish_to_topic",
                    reason => emqx_reason_codes:name(Rc)
                },
                #{topic => Topic}
            ),
            case QoS of
                ?QOS_0 ->
                    ok = emqx_metrics:inc('packets.publish.dropped'),
                    {ok, NChannel};
                ?QOS_1 ->
                    handle_out(puback, {PacketId, Rc}, NChannel);
                ?QOS_2 ->
                    handle_out(pubrec, {PacketId, Rc}, NChannel)
            end;
        {error, Rc, NChannel} ->
            ?SLOG(
                warning,
                #{
                    msg => "cannot_publish_to_topic",
                    topic => Topic,
                    reason => emqx_reason_codes:name(Rc)
                },
                #{topic => Topic}
            ),
            handle_out(disconnect, Rc, NChannel)
    end.

packet_to_message(Packet, #channel{
    conninfo = #{proto_ver := ProtoVer},
    clientinfo = #{
        protocol := Protocol,
        clientid := ClientId,
        username := Username,
        peerhost := PeerHost,
        mountpoint := MountPoint
    }
}) ->
    emqx_mountpoint:mount(
        MountPoint,
        emqx_packet:to_message(
            Packet,
            ClientId,
            #{
                proto_ver => ProtoVer,
                protocol => Protocol,
                username => Username,
                peerhost => PeerHost
            }
        )
    ).

do_publish(_PacketId, Msg = #message{qos = ?QOS_0}, Channel) ->
    Result = emqx_broker:publish(Msg),
    NChannel = ensure_quota(Result, Channel),
    {ok, NChannel};
do_publish(PacketId, Msg = #message{qos = ?QOS_1}, Channel) ->
    PubRes = emqx_broker:publish(Msg),
    RC = puback_reason_code(PacketId, Msg, PubRes),
    case RC of
        undefined ->
            {ok, Channel};
        _Value ->
            do_finish_publish(PacketId, PubRes, RC, Channel)
    end;
do_publish(
    PacketId,
    Msg = #message{qos = ?QOS_2},
    Channel = #channel{clientinfo = ClientInfo, session = Session}
) ->
    case emqx_session:publish(ClientInfo, PacketId, Msg, Session) of
        {ok, PubRes, NSession} ->
            RC = pubrec_reason_code(PubRes),
            NChannel0 = Channel#channel{session = NSession},
            NChannel1 = ensure_timer(expire_awaiting_rel, NChannel0),
            NChannel2 = ensure_quota(PubRes, NChannel1),
            handle_out(pubrec, {PacketId, RC}, NChannel2);
        {error, RC = ?RC_PACKET_IDENTIFIER_IN_USE} ->
            ok = emqx_metrics:inc('packets.publish.inuse'),
            handle_out(pubrec, {PacketId, RC}, Channel);
        {error, RC = ?RC_RECEIVE_MAXIMUM_EXCEEDED} ->
            ok = emqx_metrics:inc('packets.publish.dropped'),
            handle_out(disconnect, RC, Channel)
    end.

do_finish_publish(PacketId, PubRes, RC, Channel) ->
    NChannel = ensure_quota(PubRes, Channel),
    handle_out(puback, {PacketId, RC}, NChannel).

ensure_quota(_, Channel = #channel{quota = infinity}) ->
    Channel;
ensure_quota(PubRes, Channel = #channel{quota = Limiter}) ->
    Cnt = lists:foldl(
        fun
            ({_, _, ok}, N) -> N + 1;
            ({_, _, {ok, I}}, N) -> N + I;
            (_, N) -> N
        end,
        1,
        PubRes
    ),
    case emqx_limiter_container:check(Cnt, ?LIMITER_ROUTING, Limiter) of
        {ok, NLimiter} ->
            Channel#channel{quota = NLimiter};
        {_, Intv, NLimiter} ->
            ensure_timer(expire_quota_limit, Intv, Channel#channel{quota = NLimiter})
    end.

-compile({inline, [pubrec_reason_code/1]}).
pubrec_reason_code([]) -> ?RC_NO_MATCHING_SUBSCRIBERS;
pubrec_reason_code([_ | _]) -> ?RC_SUCCESS.

puback_reason_code(PacketId, Msg, [] = PubRes) ->
    emqx_hooks:run_fold('message.puback', [PacketId, Msg, PubRes], ?RC_NO_MATCHING_SUBSCRIBERS);
puback_reason_code(PacketId, Msg, [_ | _] = PubRes) ->
    emqx_hooks:run_fold('message.puback', [PacketId, Msg, PubRes], ?RC_SUCCESS).

-compile({inline, [after_message_acked/3]}).
after_message_acked(ClientInfo, Msg, PubAckProps) ->
    ok = emqx_metrics:inc('messages.acked'),
    emqx_hooks:run('message.acked', [
        ClientInfo,
        emqx_message:set_header(puback_props, PubAckProps, Msg)
    ]).

%%--------------------------------------------------------------------
%% Process Subscribe
%%--------------------------------------------------------------------

process_subscribe(TopicFilters, Channel) ->
    process_subscribe(TopicFilters, Channel, []).

process_subscribe([], Channel, Acc) ->
    {lists:reverse(Acc), Channel};
process_subscribe([Filter = {TopicFilter, SubOpts} | More], Channel, Acc) ->
    {NReasonCode, NChannel} = do_subscribe(TopicFilter, SubOpts, Channel),
    process_subscribe(More, NChannel, [{Filter, NReasonCode} | Acc]).

do_subscribe(
    TopicFilter,
    SubOpts = #{qos := QoS},
    Channel =
        #channel{
            clientinfo = ClientInfo = #{mountpoint := MountPoint},
            session = Session
        }
) ->
    %% TODO && FIXME (EMQX-10786): mount topic before authz check.
    NTopicFilter = emqx_mountpoint:mount(MountPoint, TopicFilter),
    case emqx_session:subscribe(ClientInfo, NTopicFilter, SubOpts, Session) of
        {ok, NSession} ->
            %% TODO && FIXME (EMQX-11216): QoS as ReasonCode(max granted QoS) for now
            RC = QoS,
            {RC, Channel#channel{session = NSession}};
        {error, RC} ->
            ?SLOG(
                warning,
                #{
                    msg => "cannot_subscribe_topic_filter",
                    reason => emqx_reason_codes:text(RC)
                },
                #{topic => NTopicFilter}
            ),
            {RC, Channel}
    end.

gen_reason_codes(TFChecked, TFSubedWitNhRC) ->
    do_gen_reason_codes([], TFChecked, TFSubedWitNhRC).

%% Initial RC is `RC_SUCCESS | RC_NOT_AUTHORIZED`, generated by check_sub_authzs/2
%% And then TF with `RC_SUCCESS` will passing through `process_subscribe/2` and
%% NRC should override the initial RC.
do_gen_reason_codes(Acc, [], []) ->
    lists:reverse(Acc);
do_gen_reason_codes(
    Acc,
    [{_, ?RC_SUCCESS} | RestTF],
    [{_, NRC} | RestWithNRC]
) ->
    %% will passing through `process_subscribe/2`
    %% use NRC to override IintialRC
    do_gen_reason_codes([NRC | Acc], RestTF, RestWithNRC);
do_gen_reason_codes(
    Acc,
    [{_, InitialRC} | Rest],
    RestWithNRC
) ->
    %% InitialRC is not `RC_SUCCESS`, use it.
    do_gen_reason_codes([InitialRC | Acc], Rest, RestWithNRC).

%%--------------------------------------------------------------------
%% Process Unsubscribe
%%--------------------------------------------------------------------

-compile({inline, [process_unsubscribe/3]}).
process_unsubscribe(TopicFilters, UnSubProps, Channel) ->
    process_unsubscribe(TopicFilters, UnSubProps, Channel, []).

process_unsubscribe([], _UnSubProps, Channel, Acc) ->
    {lists:reverse(Acc), Channel};
process_unsubscribe([{TopicFilter, SubOpts} | More], UnSubProps, Channel, Acc) ->
    {RC, NChannel} = do_unsubscribe(TopicFilter, SubOpts#{unsub_props => UnSubProps}, Channel),
    process_unsubscribe(More, UnSubProps, NChannel, [RC | Acc]).

do_unsubscribe(
    TopicFilter,
    SubOpts,
    Channel =
        #channel{
            clientinfo = ClientInfo = #{mountpoint := MountPoint},
            session = Session
        }
) ->
    TopicFilter1 = emqx_mountpoint:mount(MountPoint, TopicFilter),
    case emqx_session:unsubscribe(ClientInfo, TopicFilter1, SubOpts, Session) of
        {ok, NSession} ->
            {?RC_SUCCESS, Channel#channel{session = NSession}};
        {error, RC} ->
            {RC, Channel}
    end.
%%--------------------------------------------------------------------
%% Process Disconnect
%%--------------------------------------------------------------------

%% MQTT-v5.0: 3.14.4 DISCONNECT Actions
maybe_clean_will_msg(?RC_SUCCESS, Channel) ->
    Channel#channel{will_msg = undefined};
maybe_clean_will_msg(_ReasonCode, Channel) ->
    Channel.

%% MQTT-v5.0: 3.14.2.2.2 Session Expiry Interval
process_disconnect(
    _ReasonCode,
    #{'Session-Expiry-Interval' := Interval},
    Channel = #channel{conninfo = #{expiry_interval := 0}}
) when
    Interval > 0
->
    handle_out(disconnect, ?RC_PROTOCOL_ERROR, Channel);
process_disconnect(ReasonCode, Properties, Channel) ->
    NChannel = maybe_update_expiry_interval(Properties, Channel),
    {ok, {close, disconnect_reason(ReasonCode)}, NChannel}.

maybe_update_expiry_interval(
    #{'Session-Expiry-Interval' := Interval},
    Channel = #channel{conninfo = ConnInfo}
) ->
    EI = timer:seconds(Interval),
    OldEI = maps:get(expiry_interval, ConnInfo, 0),
    case OldEI =:= EI of
        true ->
            Channel;
        false ->
            NChannel = Channel#channel{conninfo = ConnInfo#{expiry_interval => EI}},
            %% Check if the client turns off persistence (turning it on is disallowed)
            case EI =:= 0 andalso OldEI > 0 of
                true ->
                    ok = emqx_session:destroy(NChannel#channel.session),
                    NChannel#channel{session = undefined};
                false ->
                    NChannel
            end
    end;
maybe_update_expiry_interval(_Properties, Channel) ->
    Channel.

%%--------------------------------------------------------------------
%% Handle Delivers from broker to client
%%--------------------------------------------------------------------

-spec handle_deliver(list(emqx_types:deliver()), channel()) ->
    {ok, channel()} | {ok, replies(), channel()}.

handle_deliver(
    Delivers,
    Channel = #channel{
        takeover = true,
        pendings = Pendings
    }
) ->
    %% NOTE: Order is important here. While the takeover is in
    %% progress, the session cannot enqueue messages, since it already
    %% passed on the queue to the new connection in the session state.
    NPendings = lists:append(Pendings, maybe_nack(Delivers)),
    {ok, Channel#channel{pendings = NPendings}};
handle_deliver(
    Delivers,
    Channel = #channel{
        conn_state = disconnected,
        takeover = false,
        session = Session,
        clientinfo = ClientInfo
    }
) ->
    %% NOTE
    %% This is essentially part of `emqx_session_mem` logic, thus call it directly.
    Delivers1 = maybe_nack(Delivers),
    Messages = emqx_session:enrich_delivers(ClientInfo, Delivers1, Session),
    NSession = emqx_session_mem:enqueue(ClientInfo, Messages, Session),
    {ok, Channel#channel{session = NSession}};
handle_deliver(Delivers, Channel) ->
    Delivers1 = emqx_external_trace:start_trace_send(Delivers, trace_info(Channel)),
    do_handle_deliver(Delivers1, Channel).

do_handle_deliver(
    Delivers,
    Channel = #channel{
        session = Session,
        takeover = false,
        clientinfo = ClientInfo
    }
) ->
    case emqx_session:deliver(ClientInfo, Delivers, Session) of
        {ok, [], NSession} ->
            {ok, Channel#channel{session = NSession}};
        {ok, Publishes, NSession} ->
            NChannel = Channel#channel{session = NSession},
            handle_out(publish, Publishes, ensure_timer(retry_delivery, NChannel))
    end.

%% Nack delivers from shared subscription
maybe_nack(Delivers) ->
    lists:filter(fun not_nacked/1, Delivers).

not_nacked({deliver, _Topic, Msg}) ->
    case emqx_shared_sub:is_ack_required(Msg) of
        true ->
            ok = emqx_shared_sub:nack_no_connection(Msg),
            false;
        false ->
            true
    end.

%%--------------------------------------------------------------------
%% Handle outgoing packet
%%--------------------------------------------------------------------

-spec handle_out(atom(), term(), channel()) ->
    {ok, channel()}
    | {ok, replies(), channel()}
    | {shutdown, Reason :: term(), channel()}
    | {shutdown, Reason :: term(), replies(), channel()}.
handle_out(connack, {?RC_SUCCESS, SP, Props}, Channel = #channel{conninfo = ConnInfo}) ->
    AckProps = run_fold(
        [
            fun enrich_connack_caps/2,
            fun enrich_server_keepalive/2,
            fun enrich_response_information/2,
            fun enrich_assigned_clientid/2
        ],
        Props,
        Channel
    ),
    NAckProps = run_hooks(
        'client.connack',
        [ConnInfo, emqx_reason_codes:name(?RC_SUCCESS)],
        AckProps
    ),

    return_connack(
        ?CONNACK_PACKET(?RC_SUCCESS, SP, NAckProps),
        ensure_keepalive(NAckProps, Channel)
    );
handle_out(connack, ReasonCode, Channel = #channel{conninfo = ConnInfo}) ->
    Reason = emqx_reason_codes:name(ReasonCode),
    AckProps = run_hooks('client.connack', [ConnInfo, Reason], emqx_mqtt_props:new()),
    AckPacket = ?CONNACK_PACKET(
        case maps:get(proto_ver, ConnInfo) of
            ?MQTT_PROTO_V5 -> ReasonCode;
            _ -> emqx_reason_codes:compat(connack, ReasonCode)
        end,
        sp(false),
        AckProps
    ),
    shutdown(Reason, AckPacket, Channel);
%% Optimize?
handle_out(publish, [], Channel) ->
    {ok, Channel};
handle_out(publish, Publishes, Channel) ->
    {Packets, NChannel} = do_deliver(Publishes, Channel),
    {ok, ?REPLY_OUTGOING(Packets), NChannel};
handle_out(puback, {PacketId, ReasonCode}, Channel) ->
    {ok, ?PUBACK_PACKET(PacketId, ReasonCode), Channel};
handle_out(pubrec, {PacketId, ReasonCode}, Channel) ->
    {ok, ?PUBREC_PACKET(PacketId, ReasonCode), Channel};
handle_out(pubrel, {PacketId, ReasonCode}, Channel) ->
    {ok, ?PUBREL_PACKET(PacketId, ReasonCode), Channel};
handle_out(pubcomp, {PacketId, ReasonCode}, Channel) ->
    {ok, ?PUBCOMP_PACKET(PacketId, ReasonCode), Channel};
handle_out(suback, {PacketId, ReasonCodes}, Channel = ?IS_MQTT_V5) ->
    return_sub_unsub_ack(?SUBACK_PACKET(PacketId, ReasonCodes), Channel);
handle_out(suback, {PacketId, ReasonCodes}, Channel) ->
    ReasonCodes1 = [emqx_reason_codes:compat(suback, RC) || RC <- ReasonCodes],
    return_sub_unsub_ack(?SUBACK_PACKET(PacketId, ReasonCodes1), Channel);
handle_out(unsuback, {PacketId, ReasonCodes}, Channel = ?IS_MQTT_V5) ->
    return_sub_unsub_ack(?UNSUBACK_PACKET(PacketId, ReasonCodes), Channel);
handle_out(unsuback, {PacketId, _ReasonCodes}, Channel) ->
    return_sub_unsub_ack(?UNSUBACK_PACKET(PacketId), Channel);
handle_out(disconnect, ReasonCode, Channel) when is_integer(ReasonCode) ->
    ReasonName = disconnect_reason(ReasonCode),
    handle_out(disconnect, {ReasonCode, ReasonName}, Channel);
handle_out(disconnect, {ReasonCode, ReasonName}, Channel) ->
    handle_out(disconnect, {ReasonCode, ReasonName, #{}}, Channel);
handle_out(disconnect, {ReasonCode, ReasonName, Props}, Channel = ?IS_MQTT_V5) ->
    Packet = ?DISCONNECT_PACKET(ReasonCode, Props),
    {ok, [?REPLY_OUTGOING(Packet), ?REPLY_CLOSE(ReasonName)], Channel};
handle_out(disconnect, {_ReasonCode, ReasonName, _Props}, Channel) ->
    {ok, {close, ReasonName}, Channel};
handle_out(auth, {ReasonCode, Properties}, Channel) ->
    {ok, ?AUTH_PACKET(ReasonCode, Properties), Channel};
handle_out(Type, Data, Channel) ->
    ?SLOG(error, #{msg => "unexpected_outgoing", type => Type, data => Data}),
    {ok, Channel}.

%%--------------------------------------------------------------------
%% Return ConnAck
%%--------------------------------------------------------------------

return_connack(AckPacket, Channel) ->
    Replies = [?REPLY_EVENT(connected), ?REPLY_CONNACK(AckPacket)],
    case maybe_resume_session(Channel) of
        ignore ->
            {ok, Replies, Channel};
        {ok, Publishes, NSession} ->
            NChannel1 = Channel#channel{
                resuming = false,
                pendings = [],
                session = NSession
            },
            {Packets, NChannel2} = do_deliver(Publishes, NChannel1),
            Outgoing = [?REPLY_OUTGOING(Packets) || length(Packets) > 0],
            %% NOTE
            %% Session timers are not restored here, so there's a tiny chance that
            %% the session becomes stuck, when it already has no place to track new
            %% messages.
            {ok, Replies ++ Outgoing, NChannel2}
    end.

%%--------------------------------------------------------------------
%% Deliver publish: broker -> client
%%--------------------------------------------------------------------

%% return list(emqx_types:packet())
do_deliver({pubrel, PacketId}, Channel) ->
    {[?PUBREL_PACKET(PacketId, ?RC_SUCCESS)], Channel};
do_deliver(
    {PacketId, Msg},
    Channel = #channel{
        clientinfo =
            ClientInfo =
                #{mountpoint := MountPoint}
    }
) ->
    ok = emqx_metrics:inc('messages.delivered'),
    Msg1 = emqx_hooks:run_fold(
        'message.delivered',
        [ClientInfo],
        emqx_message:update_expiry(Msg)
    ),
    Msg2 = emqx_mountpoint:unmount(MountPoint, Msg1),
    Packet = emqx_message:to_packet(PacketId, Msg2),
    {NPacket, NChannel} = packing_alias(Packet, Channel),
    {[NPacket], NChannel};
do_deliver([Publish], Channel) ->
    do_deliver(Publish, Channel);
do_deliver(Publishes, Channel) when is_list(Publishes) ->
    {Packets, NChannel} =
        lists:foldl(
            fun(Publish, {Acc, Chann}) ->
                {Packets, NChann} = do_deliver(Publish, Chann),
                {Packets ++ Acc, NChann}
            end,
            {[], Channel},
            Publishes
        ),
    {lists:reverse(Packets), NChannel}.

%%--------------------------------------------------------------------
%% Handle out suback
%%--------------------------------------------------------------------

return_sub_unsub_ack(Packet, Channel) ->
    {ok, [?REPLY_OUTGOING(Packet), ?REPLY_EVENT(updated)], Channel}.

%%--------------------------------------------------------------------
%% Handle call
%%--------------------------------------------------------------------

-spec handle_call(Req :: term(), channel()) ->
    {reply, Reply :: term(), channel()}
    | {shutdown, Reason :: term(), Reply :: term(), channel()}
    | {shutdown, Reason :: term(), Reply :: term(), emqx_types:packet(), channel()}.
handle_call(
    kick,
    Channel = #channel{
        conn_state = ConnState,
        will_msg = WillMsg,
        clientinfo = ClientInfo,
        conninfo = #{proto_ver := ProtoVer}
    }
) ->
    (WillMsg =/= undefined) andalso publish_will_msg(ClientInfo, WillMsg),
    Channel1 =
        case ConnState of
            connected -> ensure_disconnected(kicked, Channel);
            _ -> Channel
        end,
    case ProtoVer == ?MQTT_PROTO_V5 andalso ConnState == connected of
        true ->
            shutdown(
                kicked,
                ok,
                ?DISCONNECT_PACKET(?RC_ADMINISTRATIVE_ACTION),
                Channel1
            );
        _ ->
            shutdown(kicked, ok, Channel1)
    end;
handle_call(discard, Channel) ->
    disconnect_and_shutdown(discarded, ok, Channel);
%% Session Takeover
handle_call({takeover, 'begin'}, Channel = #channel{session = Session}) ->
    reply(Session, Channel#channel{takeover = true});
handle_call(
    {takeover, 'end'},
    Channel = #channel{
        session = Session,
        pendings = Pendings,
        conninfo = #{clientid := ClientId}
    }
) ->
    %% NOTE
    %% This is essentially part of `emqx_session_mem` logic, thus call it directly.
    ok = emqx_session_mem:takeover(Session),
    %% TODO: Should not drain deliver here (side effect)
    Delivers = emqx_utils:drain_deliver(),
    AllPendings = lists:append(Pendings, maybe_nack(Delivers)),
    ?tp(
        debug,
        emqx_channel_takeover_end,
        #{clientid => ClientId}
    ),
    disconnect_and_shutdown(takenover, AllPendings, Channel);
handle_call(list_authz_cache, Channel) ->
    {reply, emqx_authz_cache:list_authz_cache(), Channel};
handle_call(
    {keepalive, Interval},
    Channel = #channel{
        keepalive = KeepAlive,
        conninfo = ConnInfo
    }
) ->
    ClientId = info(clientid, Channel),
    NKeepalive = emqx_keepalive:update(timer:seconds(Interval), KeepAlive),
    NConnInfo = maps:put(keepalive, Interval, ConnInfo),
    NChannel = Channel#channel{keepalive = NKeepalive, conninfo = NConnInfo},
    SockInfo = maps:get(sockinfo, emqx_cm:get_chan_info(ClientId), #{}),
    ChanInfo1 = info(NChannel),
    emqx_cm:set_chan_info(ClientId, ChanInfo1#{sockinfo => SockInfo}),
    reply(ok, reset_timer(keepalive, NChannel));
handle_call(Req, Channel) ->
    ?SLOG(error, #{msg => "unexpected_call", call => Req}),
    reply(ignored, Channel).

%%--------------------------------------------------------------------
%% Handle Info
%%--------------------------------------------------------------------

-spec handle_info(Info :: term(), channel()) ->
    ok | {ok, channel()} | {shutdown, Reason :: term(), channel()}.

handle_info({subscribe, TopicFilters}, Channel) ->
    NTopicFilters = enrich_subscribe(TopicFilters, Channel),
    {_TopicFiltersWithRC, NChannel} = process_subscribe(NTopicFilters, Channel),
    {ok, NChannel};
handle_info({unsubscribe, TopicFilters}, Channel) ->
    {_RC, NChannel} = process_unsubscribe(TopicFilters, #{}, Channel),
    {ok, NChannel};
handle_info({sock_closed, Reason}, Channel = #channel{conn_state = idle}) ->
    shutdown(Reason, Channel);
handle_info({sock_closed, Reason}, Channel = #channel{conn_state = connecting}) ->
    shutdown(Reason, Channel);
handle_info(
    {sock_closed, Reason},
    Channel =
        #channel{
            conn_state = ConnState,
            clientinfo = ClientInfo,
            conninfo = ConnInfo,
            session = Session
        }
) when
    ConnState =:= connected orelse ConnState =:= reauthenticating
->
    {Intent, Session1} = session_disconnect(ClientInfo, ConnInfo, Session),
    Channel1 = ensure_disconnected(Reason, maybe_publish_will_msg(Channel)),
    Channel2 = Channel1#channel{session = Session1},
    case maybe_shutdown(Reason, Intent, Channel2) of
        {ok, Channel3} -> {ok, ?REPLY_EVENT(disconnected), Channel3};
        Shutdown -> Shutdown
    end;
handle_info({sock_closed, _Reason}, Channel = #channel{conn_state = disconnected}) ->
    %% This can happen as a race:
    %% EMQX closes socket and marks 'disconnected' but 'tcp_closed' or 'ssl_closed'
    %% is already in process mailbox
    {ok, Channel};
handle_info(clean_authz_cache, Channel) ->
    ok = emqx_authz_cache:empty_authz_cache(),
    {ok, Channel};
handle_info(die_if_test = Info, Channel) ->
    die_if_test_compiled(),
    ?SLOG(error, #{msg => "unexpected_info", info => Info}),
    {ok, Channel};
handle_info({disconnect, ReasonCode, ReasonName, Props}, Channel) ->
    handle_out(disconnect, {ReasonCode, ReasonName, Props}, Channel);
handle_info({puback, PacketId, PubRes, RC}, Channel) ->
    do_finish_publish(PacketId, PubRes, RC, Channel);
handle_info({'DOWN', Ref, process, Pid, Reason}, Channel) ->
    case emqx_hooks:run_fold('client.monitored_process_down', [Ref, Pid, Reason], []) of
        [] -> {ok, Channel};
        Msgs -> {ok, Msgs, Channel}
    end;
handle_info(Info, Channel) ->
    ?SLOG(error, #{msg => "unexpected_info", info => Info}),
    {ok, Channel}.

-ifdef(TEST).

-spec die_if_test_compiled() -> no_return().
die_if_test_compiled() ->
    exit(normal).

-else.

die_if_test_compiled() ->
    ok.

-endif.

%%--------------------------------------------------------------------
%% Handle timeout
%%--------------------------------------------------------------------

-spec handle_timeout(reference(), Msg :: term(), channel()) ->
    {ok, channel()}
    | {ok, replies(), channel()}
    | {shutdown, Reason :: term(), channel()}.
handle_timeout(
    _TRef,
    {keepalive, _StatVal},
    Channel = #channel{keepalive = undefined}
) ->
    {ok, Channel};
handle_timeout(
    _TRef,
    {keepalive, _StatVal},
    Channel = #channel{conn_state = disconnected}
) ->
    {ok, Channel};
handle_timeout(
    _TRef,
    {keepalive, StatVal},
    Channel = #channel{keepalive = Keepalive}
) ->
    case emqx_keepalive:check(StatVal, Keepalive) of
        {ok, NKeepalive} ->
            NChannel = Channel#channel{keepalive = NKeepalive},
            {ok, reset_timer(keepalive, NChannel)};
        {error, timeout} ->
            handle_out(disconnect, ?RC_KEEP_ALIVE_TIMEOUT, Channel)
    end;
handle_timeout(
    _TRef,
    TimerName,
    Channel = #channel{conn_state = disconnected}
) when ?IS_COMMON_SESSION_TIMER(TimerName) ->
    {ok, Channel};
handle_timeout(
    _TRef,
    TimerName,
    Channel = #channel{session = Session, clientinfo = ClientInfo}
) when ?IS_COMMON_SESSION_TIMER(TimerName) ->
    %% NOTE
    %% Responsibility for these timers is smeared across both this module and the
    %% `emqx_session` module: the latter holds configured timer intervals, and is
    %% responsible for the actual timeout logic. Yet they are managed here, since
    %% they are kind of common to all session implementations.
    case emqx_session:handle_timeout(ClientInfo, TimerName, Session) of
        {ok, Publishes, NSession} ->
            NChannel = Channel#channel{session = NSession},
            handle_out(publish, Publishes, clean_timer(TimerName, NChannel));
        {ok, Publishes, Timeout, NSession} ->
            NChannel = Channel#channel{session = NSession},
            handle_out(publish, Publishes, reset_timer(TimerName, Timeout, NChannel))
    end;
handle_timeout(
    _TRef,
    {emqx_session, TimerName},
    Channel = #channel{session = Session, clientinfo = ClientInfo}
) ->
    case emqx_session:handle_timeout(ClientInfo, TimerName, Session) of
        {ok, [], NSession} ->
            {ok, Channel#channel{session = NSession}};
        {ok, Replies, NSession} ->
            handle_out(publish, Replies, Channel#channel{session = NSession})
    end;
handle_timeout(_TRef, expire_session, Channel = #channel{session = Session}) ->
    ok = emqx_session:destroy(Session),
    shutdown(expired, Channel);
handle_timeout(
    _TRef,
    will_message = TimerName,
    Channel = #channel{clientinfo = ClientInfo, will_msg = WillMsg}
) ->
    (WillMsg =/= undefined) andalso publish_will_msg(ClientInfo, WillMsg),
    {ok, clean_timer(TimerName, Channel#channel{will_msg = undefined})};
handle_timeout(
    _TRef,
    expire_quota_limit = TimerName,
    #channel{quota = Quota} = Channel
) ->
    case emqx_limiter_container:retry(?LIMITER_ROUTING, Quota) of
        {_, Intv, Quota2} ->
            Channel2 = ensure_timer(TimerName, Intv, Channel#channel{quota = Quota2}),
            {ok, Channel2};
        {_, Quota2} ->
            {ok, clean_timer(TimerName, Channel#channel{quota = Quota2})}
    end;
handle_timeout(TRef, Msg, Channel) ->
    case emqx_hooks:run_fold('client.timeout', [TRef, Msg], []) of
        [] ->
            {ok, Channel};
        Msgs ->
            {ok, Msgs, Channel}
    end.

%%--------------------------------------------------------------------
%% Ensure timers
%%--------------------------------------------------------------------

ensure_timer([Name], Channel) ->
    ensure_timer(Name, Channel);
ensure_timer([Name | Rest], Channel) ->
    ensure_timer(Rest, ensure_timer(Name, Channel));
ensure_timer(Name, Channel = #channel{timers = Timers}) ->
    TRef = maps:get(Name, Timers, undefined),
    Time = interval(Name, Channel),
    case TRef == undefined andalso Time > 0 of
        true -> ensure_timer(Name, Time, Channel);
        %% Timer disabled or exists
        false -> Channel
    end.

ensure_timer(Name, Time, Channel = #channel{timers = Timers}) ->
    TRef = emqx_utils:start_timer(Time, Name),
    Channel#channel{timers = Timers#{Name => TRef}}.

reset_timer(Name, Channel) ->
    ensure_timer(Name, clean_timer(Name, Channel)).

reset_timer(Name, Time, Channel) ->
    ensure_timer(Name, Time, clean_timer(Name, Channel)).

clean_timer(Name, Channel = #channel{timers = Timers}) ->
    Channel#channel{timers = maps:remove(Name, Timers)}.

interval(keepalive, #channel{keepalive = KeepAlive}) ->
    emqx_keepalive:info(interval, KeepAlive);
interval(retry_delivery, #channel{session = Session}) ->
    emqx_session:info(retry_interval, Session);
interval(expire_awaiting_rel, #channel{session = Session}) ->
    emqx_session:info(await_rel_timeout, Session);
interval(expire_session, #channel{conninfo = ConnInfo}) ->
    maps:get(expiry_interval, ConnInfo);
interval(will_message, #channel{will_msg = WillMsg}) ->
    timer:seconds(will_delay_interval(WillMsg)).

%%--------------------------------------------------------------------
%% Terminate
%%--------------------------------------------------------------------

-spec terminate(any(), channel()) -> ok.
terminate(_, #channel{conn_state = idle} = _Channel) ->
    ok;
terminate(normal, Channel) ->
    run_terminate_hook(normal, Channel);
terminate({shutdown, kicked}, Channel) ->
    run_terminate_hook(kicked, Channel);
terminate({shutdown, Reason}, Channel) when
    Reason =:= discarded;
    Reason =:= takenover
->
    run_terminate_hook(Reason, Channel);
terminate(Reason, Channel = #channel{clientinfo = ClientInfo, will_msg = WillMsg}) ->
    %% since will_msg is set to undefined as soon as it is published,
    %% if will_msg still exists when the session is terminated, it
    %% must be published immediately.
    WillMsg =/= undefined andalso publish_will_msg(ClientInfo, WillMsg),
    run_terminate_hook(Reason, Channel).

run_terminate_hook(_Reason, #channel{session = undefined}) ->
    ok;
run_terminate_hook(Reason, #channel{clientinfo = ClientInfo, session = Session}) ->
    emqx_session:terminate(ClientInfo, Reason, Session).

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------
overload_protection(_, #channel{clientinfo = #{zone := Zone}}) ->
    emqx_olp:backoff(Zone),
    ok.

trace_info(Channel) ->
    %% More info can be added in future, but for now only clientid is used
    maps:from_list(info([clientid], Channel)).

%%--------------------------------------------------------------------
%% Enrich MQTT Connect Info

enrich_conninfo(
    ConnPkt = #mqtt_packet_connect{
        proto_name = ProtoName,
        proto_ver = ProtoVer,
        clean_start = CleanStart,
        keepalive = Keepalive,
        properties = ConnProps,
        clientid = ClientId,
        username = Username
    },
    Channel = #channel{
        conninfo = ConnInfo,
        clientinfo = #{zone := Zone}
    }
) ->
    ExpiryInterval = expiry_interval(Zone, ConnPkt),
    NConnInfo = ConnInfo#{
        proto_name => ProtoName,
        proto_ver => ProtoVer,
        clean_start => CleanStart,
        keepalive => Keepalive,
        clientid => ClientId,
        username => Username,
        conn_props => ConnProps,
        expiry_interval => ExpiryInterval,
        receive_maximum => receive_maximum(Zone, ConnProps)
    },
    {ok, Channel#channel{conninfo = NConnInfo}}.

%% If the Session Expiry Interval is absent the value 0 is used.
expiry_interval(_, #mqtt_packet_connect{
    proto_ver = ?MQTT_PROTO_V5,
    properties = ConnProps
}) ->
    timer:seconds(emqx_mqtt_props:get('Session-Expiry-Interval', ConnProps, 0));
expiry_interval(Zone, #mqtt_packet_connect{clean_start = false}) ->
    get_mqtt_conf(Zone, session_expiry_interval);
expiry_interval(_, #mqtt_packet_connect{clean_start = true}) ->
    0.

receive_maximum(Zone, ConnProps) ->
    MaxInflightConfig =
        case get_mqtt_conf(Zone, max_inflight) of
            0 -> ?RECEIVE_MAXIMUM_LIMIT;
            N -> N
        end,
    %% Received might be zero which should be a protocol error
    %% we do not validate MQTT properties here
    %% it is to be caught later
    Received = emqx_mqtt_props:get('Receive-Maximum', ConnProps, MaxInflightConfig),
    erlang:min(Received, MaxInflightConfig).

%%--------------------------------------------------------------------
%% Run Connect Hooks

run_conn_hooks(ConnPkt, Channel = #channel{conninfo = ConnInfo}) ->
    ConnProps = emqx_packet:info(properties, ConnPkt),
    case run_hooks('client.connect', [ConnInfo], ConnProps) of
        Error = {error, _Reason} -> Error;
        NConnProps -> {ok, emqx_packet:set_props(NConnProps, ConnPkt), Channel}
    end.

%%--------------------------------------------------------------------
%% Check Connect Packet

check_connect(ConnPkt, #channel{clientinfo = #{zone := Zone}}) ->
    emqx_packet:check(ConnPkt, emqx_mqtt_caps:get_caps(Zone)).

%%--------------------------------------------------------------------
%% Enrich Client Info

enrich_client(ConnPkt, Channel = #channel{clientinfo = ClientInfo}) ->
    Pipe = pipeline(
        [
            fun set_username/2,
            fun set_bridge_mode/2,
            fun maybe_username_as_clientid/2,
            fun maybe_assign_clientid/2,
            fun fix_mountpoint/2
        ],
        ConnPkt,
        ClientInfo
    ),
    case Pipe of
        {ok, NConnPkt, NClientInfo} ->
            {ok, NConnPkt, Channel#channel{clientinfo = NClientInfo}};
        {error, ReasonCode, NClientInfo} ->
            {error, ReasonCode, Channel#channel{clientinfo = NClientInfo}}
    end.

set_username(
    #mqtt_packet_connect{username = Username},
    ClientInfo = #{username := undefined}
) ->
    {ok, ClientInfo#{username => Username}};
set_username(_ConnPkt, ClientInfo) ->
    {ok, ClientInfo}.

set_bridge_mode(#mqtt_packet_connect{is_bridge = true}, ClientInfo) ->
    {ok, ClientInfo#{is_bridge => true}};
set_bridge_mode(_ConnPkt, _ClientInfo) ->
    ok.

maybe_username_as_clientid(_ConnPkt, ClientInfo = #{username := undefined}) ->
    {ok, ClientInfo};
maybe_username_as_clientid(
    _ConnPkt,
    ClientInfo = #{
        zone := Zone,
        username := Username
    }
) ->
    case get_mqtt_conf(Zone, use_username_as_clientid) of
        true when Username =/= <<>> -> {ok, ClientInfo#{clientid => Username}};
        true -> {error, ?RC_CLIENT_IDENTIFIER_NOT_VALID, ClientInfo};
        false -> ok
    end.

maybe_assign_clientid(_ConnPkt, ClientInfo = #{clientid := ClientId}) when
    ClientId /= undefined
->
    {ok, ClientInfo};
maybe_assign_clientid(#mqtt_packet_connect{clientid = <<>>}, ClientInfo) ->
    %% Generate a rand clientId
    {ok, ClientInfo#{clientid => emqx_guid:to_base62(emqx_guid:gen())}};
maybe_assign_clientid(#mqtt_packet_connect{clientid = ClientId}, ClientInfo) ->
    {ok, ClientInfo#{clientid => ClientId}}.

fix_mountpoint(_ConnPkt, #{mountpoint := undefined}) ->
    ok;
fix_mountpoint(_ConnPkt, ClientInfo = #{mountpoint := MountPoint}) ->
    MountPoint1 = emqx_mountpoint:replvar(MountPoint, ClientInfo),
    {ok, ClientInfo#{mountpoint := MountPoint1}}.

%%--------------------------------------------------------------------
%% Set log metadata

set_log_meta(_ConnPkt, #channel{clientinfo = #{clientid := ClientId}}) ->
    emqx_logger:set_metadata_clientid(ClientId).

%%--------------------------------------------------------------------
%% Check banned

check_banned(_ConnPkt, #channel{clientinfo = ClientInfo}) ->
    case emqx_banned:check(ClientInfo) of
        true -> {error, ?RC_BANNED};
        false -> ok
    end.

%%--------------------------------------------------------------------
%% Flapping

count_flapping_event(_ConnPkt, #channel{clientinfo = ClientInfo}) ->
    _ = emqx_flapping:detect(ClientInfo),
    ok.

%%--------------------------------------------------------------------
%% Authenticate

authenticate(
    ?CONNECT_PACKET(
        #mqtt_packet_connect{
            proto_ver = ?MQTT_PROTO_V5,
            properties = #{'Authentication-Method' := AuthMethod} = Properties
        }
    ),
    #channel{
        clientinfo = ClientInfo,
        auth_cache = AuthCache
    } = Channel
) ->
    AuthData = emqx_mqtt_props:get('Authentication-Data', Properties, undefined),
    do_authenticate(
        ClientInfo#{
            auth_method => AuthMethod,
            auth_data => AuthData,
            auth_cache => AuthCache
        },
        Channel
    );
authenticate(
    ?CONNECT_PACKET(#mqtt_packet_connect{password = Password}),
    #channel{clientinfo = ClientInfo} = Channel
) ->
    do_authenticate(ClientInfo#{password => Password}, Channel);
authenticate(
    ?AUTH_PACKET(_, #{'Authentication-Method' := AuthMethod} = Properties),
    #channel{
        clientinfo = ClientInfo,
        conninfo = #{conn_props := ConnProps},
        auth_cache = AuthCache
    } = Channel
) ->
    case emqx_mqtt_props:get('Authentication-Method', ConnProps, undefined) of
        AuthMethod ->
            AuthData = emqx_mqtt_props:get('Authentication-Data', Properties, undefined),
            do_authenticate(
                ClientInfo#{
                    auth_method => AuthMethod,
                    auth_data => AuthData,
                    auth_cache => AuthCache
                },
                Channel
            );
        _ ->
            {error, ?RC_BAD_AUTHENTICATION_METHOD}
    end.

do_authenticate(
    #{auth_method := AuthMethod} = Credential,
    #channel{clientinfo = ClientInfo} = Channel
) ->
    Properties = #{'Authentication-Method' => AuthMethod},
    case emqx_access_control:authenticate(Credential) of
        {ok, AuthResult} ->
            {ok, Properties, Channel#channel{
                clientinfo = merge_auth_result(ClientInfo, AuthResult),
                auth_cache = #{}
            }};
        {ok, AuthResult, AuthData} ->
            {ok, Properties#{'Authentication-Data' => AuthData}, Channel#channel{
                clientinfo = merge_auth_result(ClientInfo, AuthResult),
                auth_cache = #{}
            }};
        {continue, AuthCache} ->
            {continue, Properties, Channel#channel{auth_cache = AuthCache}};
        {continue, AuthData, AuthCache} ->
            {continue, Properties#{'Authentication-Data' => AuthData}, Channel#channel{
                auth_cache = AuthCache
            }};
        {error, Reason} ->
            {error, emqx_reason_codes:connack_error(Reason)}
    end;
do_authenticate(Credential, #channel{clientinfo = ClientInfo} = Channel) ->
    case emqx_access_control:authenticate(Credential) of
        {ok, AuthResult} ->
            {ok, #{}, Channel#channel{clientinfo = merge_auth_result(ClientInfo, AuthResult)}};
        {error, Reason} ->
            {error, emqx_reason_codes:connack_error(Reason)}
    end.

merge_auth_result(ClientInfo, AuthResult) when is_map(ClientInfo) andalso is_map(AuthResult) ->
    IsSuperuser = maps:get(is_superuser, AuthResult, false),
    maps:merge(ClientInfo, AuthResult#{is_superuser => IsSuperuser}).

%%--------------------------------------------------------------------
%% Process Topic Alias

process_alias(
    Packet = #mqtt_packet{
        variable =
            #mqtt_packet_publish{
                topic_name = <<>>,
                properties = #{'Topic-Alias' := AliasId}
            } = Publish
    },
    Channel = ?IS_MQTT_V5 = #channel{topic_aliases = TopicAliases}
) ->
    case find_alias(inbound, AliasId, TopicAliases) of
        {ok, Topic} ->
            NPublish = Publish#mqtt_packet_publish{topic_name = Topic},
            {ok, Packet#mqtt_packet{variable = NPublish}, Channel};
        error ->
            {error, ?RC_PROTOCOL_ERROR}
    end;
process_alias(
    #mqtt_packet{
        variable = #mqtt_packet_publish{
            topic_name = Topic,
            properties = #{'Topic-Alias' := AliasId}
        }
    },
    Channel = ?IS_MQTT_V5 = #channel{topic_aliases = TopicAliases}
) ->
    NTopicAliases = save_alias(inbound, AliasId, Topic, TopicAliases),
    {ok, Channel#channel{topic_aliases = NTopicAliases}};
process_alias(_Packet, Channel) ->
    {ok, Channel}.

%%--------------------------------------------------------------------
%% Packing Topic Alias

packing_alias(
    Packet = #mqtt_packet{
        variable =
            #mqtt_packet_publish{
                topic_name = Topic,
                properties = Prop
            } = Publish
    },
    Channel =
        ?IS_MQTT_V5 = #channel{
            topic_aliases = TopicAliases,
            alias_maximum = Limits
        }
) ->
    case find_alias(outbound, Topic, TopicAliases) of
        {ok, AliasId} ->
            NPublish = Publish#mqtt_packet_publish{
                topic_name = <<>>,
                properties = maps:merge(Prop, #{'Topic-Alias' => AliasId})
            },
            {Packet#mqtt_packet{variable = NPublish}, Channel};
        error ->
            #{outbound := Aliases} = TopicAliases,
            AliasId = maps:size(Aliases) + 1,
            case
                (Limits =:= undefined) orelse
                    (AliasId =< maps:get(outbound, Limits, 0))
            of
                true ->
                    NTopicAliases = save_alias(outbound, AliasId, Topic, TopicAliases),
                    NChannel = Channel#channel{topic_aliases = NTopicAliases},
                    NPublish = Publish#mqtt_packet_publish{
                        topic_name = Topic,
                        properties = maps:merge(Prop, #{'Topic-Alias' => AliasId})
                    },
                    {Packet#mqtt_packet{variable = NPublish}, NChannel};
                false ->
                    {Packet, Channel}
            end
    end;
packing_alias(Packet, Channel) ->
    {Packet, Channel}.

%%--------------------------------------------------------------------
%% Check quota state

check_quota_exceeded(_, #channel{timers = Timers}) ->
    case maps:get(expire_quota_limit, Timers, undefined) of
        undefined -> ok;
        _ -> {error, ?RC_QUOTA_EXCEEDED}
    end.

%%--------------------------------------------------------------------
%% Check Pub Alias

check_pub_alias(
    #mqtt_packet{
        variable = #mqtt_packet_publish{
            properties = #{'Topic-Alias' := AliasId}
        }
    },
    #channel{alias_maximum = Limits}
) ->
    case
        (Limits =:= undefined) orelse
            (AliasId =< maps:get(inbound, Limits, ?MAX_TOPIC_AlIAS))
    of
        true -> ok;
        false -> {error, ?RC_TOPIC_ALIAS_INVALID}
    end;
check_pub_alias(_Packet, _Channel) ->
    ok.

%%--------------------------------------------------------------------
%% Authorization action

authz_action(#mqtt_packet{
    header = #mqtt_packet_header{qos = QoS, retain = Retain}, variable = #mqtt_packet_publish{}
}) ->
    ?AUTHZ_PUBLISH(QoS, Retain);
authz_action({_Topic, #{qos := QoS} = _SubOpts} = _TopicFilter) ->
    ?AUTHZ_SUBSCRIBE(QoS);
%% Will message
authz_action(#message{qos = QoS, flags = #{retain := Retain}}) ->
    ?AUTHZ_PUBLISH(QoS, Retain);
authz_action(#message{qos = QoS}) ->
    ?AUTHZ_PUBLISH(QoS).

%%--------------------------------------------------------------------
%% Check Pub Authorization

check_pub_authz(
    #mqtt_packet{
        variable = #mqtt_packet_publish{topic_name = Topic}
    } = Packet,
    #channel{clientinfo = ClientInfo}
) ->
    Action = authz_action(Packet),
    case emqx_access_control:authorize(ClientInfo, Action, Topic) of
        allow -> ok;
        deny -> {error, ?RC_NOT_AUTHORIZED}
    end.

%%--------------------------------------------------------------------
%% Check Pub Caps

check_pub_caps(
    #mqtt_packet{
        header = #mqtt_packet_header{
            qos = QoS,
            retain = Retain
        },
        variable = #mqtt_packet_publish{topic_name = Topic}
    },
    #channel{clientinfo = #{zone := Zone}}
) ->
    emqx_mqtt_caps:check_pub(Zone, #{qos => QoS, retain => Retain, topic => Topic}).

%%--------------------------------------------------------------------
%% Check Subscribe Packet

check_subscribe(SubPkt, _Channel) ->
    case emqx_packet:check(SubPkt) of
        ok -> ok;
        {error, RC} -> {error, {disconnect, RC}}
    end.

%%--------------------------------------------------------------------
%% Check Sub Authorization

check_sub_authzs(
    ?SUBSCRIBE_PACKET(PacketId, SubProps, TopicFilters0),
    Channel = #channel{clientinfo = ClientInfo}
) ->
    CheckResult = do_check_sub_authzs(TopicFilters0, ClientInfo),
    HasAuthzDeny = lists:any(
        fun({{_TopicFilter, _SubOpts}, ReasonCode}) ->
            ReasonCode =:= ?RC_NOT_AUTHORIZED
        end,
        CheckResult
    ),
    DenyAction = emqx:get_config([authorization, deny_action], ignore),
    case DenyAction =:= disconnect andalso HasAuthzDeny of
        true ->
            {error, {disconnect, ?RC_NOT_AUTHORIZED}, Channel};
        false ->
            {ok, ?SUBSCRIBE_PACKET(PacketId, SubProps, CheckResult), Channel}
    end.

do_check_sub_authzs(TopicFilters, ClientInfo) ->
    do_check_sub_authzs(ClientInfo, TopicFilters, []).

do_check_sub_authzs(_ClientInfo, [], Acc) ->
    lists:reverse(Acc);
do_check_sub_authzs(ClientInfo, [TopicFilter = {Topic, _SubOpts} | More], Acc) ->
    %% subsclibe authz check only cares the real topic filter when shared-sub
    %% e.g. only check <<"t/#">> for <<"$share/g/t/#">>
    Action = authz_action(TopicFilter),
    case
        emqx_access_control:authorize(
            ClientInfo,
            Action,
            emqx_topic:get_shared_real_topic(Topic)
        )
    of
        %% TODO: support maximum QoS granted
        %% MQTT-3.1.1 [MQTT-3.8.4-6] and MQTT-5.0 [MQTT-3.8.4-7]
        %% Not implemented yet:
        %% {allow, RC} -> do_check_sub_authzs(ClientInfo, More, [{TopicFilter, RC} | Acc]);
        allow ->
            do_check_sub_authzs(ClientInfo, More, [{TopicFilter, ?RC_SUCCESS} | Acc]);
        deny ->
            do_check_sub_authzs(ClientInfo, More, [{TopicFilter, ?RC_NOT_AUTHORIZED} | Acc])
    end.

%%--------------------------------------------------------------------
%% Check Sub Caps

check_sub_caps(
    ?SUBSCRIBE_PACKET(PacketId, SubProps, TopicFilters),
    Channel = #channel{clientinfo = ClientInfo}
) ->
    CheckResult = do_check_sub_caps(ClientInfo, TopicFilters),
    {ok, ?SUBSCRIBE_PACKET(PacketId, SubProps, CheckResult), Channel}.

do_check_sub_caps(ClientInfo, TopicFilters) ->
    do_check_sub_caps(ClientInfo, TopicFilters, []).

do_check_sub_caps(_ClientInfo, [], Acc) ->
    lists:reverse(Acc);
do_check_sub_caps(ClientInfo, [TopicFilter = {{Topic, SubOpts}, ?RC_SUCCESS} | More], Acc) ->
    case emqx_mqtt_caps:check_sub(ClientInfo, Topic, SubOpts) of
        ok ->
            do_check_sub_caps(ClientInfo, More, [TopicFilter | Acc]);
        {error, NRC} ->
            ?SLOG(
                warning,
                #{
                    msg => "cannot_subscribe_topic_filter",
                    reason => emqx_reason_codes:name(NRC)
                },
                #{topic => Topic}
            ),
            do_check_sub_caps(ClientInfo, More, [{{Topic, SubOpts}, NRC} | Acc])
    end;
do_check_sub_caps(ClientInfo, [TopicFilter = {{_Topic, _SubOpts}, _OtherRC} | More], Acc) ->
    do_check_sub_caps(ClientInfo, More, [TopicFilter | Acc]).

%%--------------------------------------------------------------------
%% Run Subscribe Hooks

run_sub_hooks(
    ?SUBSCRIBE_PACKET(_PacketId, Properties, TopicFilters0),
    _Channel = #channel{clientinfo = ClientInfo}
) ->
    TopicFilters = [
        TopicFilter
     || {TopicFilter, ?RC_SUCCESS} <- TopicFilters0
    ],
    _NTopicFilters = run_hooks('client.subscribe', [ClientInfo, Properties], TopicFilters).

%%--------------------------------------------------------------------
%% Enrich SubOpts

%% for api subscribe without sub-authz check and sub-caps check.
enrich_subscribe(TopicFilters, Channel) when is_list(TopicFilters) ->
    do_enrich_subscribe(#{}, TopicFilters, Channel);
%% for mqtt clients sent subscribe packet.
enrich_subscribe(?SUBSCRIBE_PACKET(PacketId, Properties, TopicFilters), Channel) ->
    NTopicFilters = do_enrich_subscribe(Properties, TopicFilters, Channel),
    {ok, ?SUBSCRIBE_PACKET(PacketId, Properties, NTopicFilters), Channel}.

do_enrich_subscribe(Properties, TopicFilters, Channel) ->
    _NTopicFilters = run_fold(
        [
            %% TODO: do try catch with reason code here
            fun(TFs, _) -> parse_raw_topic_filters(TFs) end,
            fun enrich_subopts_subid/2,
            fun enrich_subopts_porps/2,
            fun enrich_subopts_flags/2
        ],
        TopicFilters,
        #{sub_props => Properties, channel => Channel}
    ).

enrich_subopts_subid(TopicFilters, #{sub_props := #{'Subscription-Identifier' := SubId}}) ->
    [{Topic, SubOpts#{subid => SubId}} || {Topic, SubOpts} <- TopicFilters];
enrich_subopts_subid(TopicFilters, _State) ->
    TopicFilters.

enrich_subopts_porps(TopicFilters, #{sub_props := SubProps}) ->
    [{Topic, SubOpts#{sub_props => SubProps}} || {Topic, SubOpts} <- TopicFilters].

enrich_subopts_flags(TopicFilters, #{channel := Channel}) ->
    do_enrich_subopts_flags(TopicFilters, Channel).

do_enrich_subopts_flags(TopicFilters, ?IS_MQTT_V5) ->
    [{Topic, merge_default_subopts(SubOpts)} || {Topic, SubOpts} <- TopicFilters];
do_enrich_subopts_flags(TopicFilters, #channel{clientinfo = #{zone := Zone, is_bridge := IsBridge}}) ->
    Rap = flag(IsBridge),
    NL = flag(get_mqtt_conf(Zone, ignore_loop_deliver)),
    [
        {Topic, (merge_default_subopts(SubOpts))#{rap => Rap, nl => NL}}
     || {Topic, SubOpts} <- TopicFilters
    ].

merge_default_subopts(SubOpts) ->
    maps:merge(?DEFAULT_SUBOPTS, SubOpts).

%%--------------------------------------------------------------------
%% Enrich ConnAck Caps

enrich_connack_caps(
    AckProps,
    ?IS_MQTT_V5 = #channel{
        clientinfo = #{
            zone := Zone
        }
    }
) ->
    #{
        max_packet_size := MaxPktSize,
        max_qos_allowed := MaxQoS,
        retain_available := Retain,
        max_topic_alias := MaxAlias,
        shared_subscription := Shared,
        wildcard_subscription := Wildcard
    } = emqx_mqtt_caps:get_caps(Zone),
    NAckProps = AckProps#{
        'Retain-Available' => flag(Retain),
        'Maximum-Packet-Size' => MaxPktSize,
        'Topic-Alias-Maximum' => MaxAlias,
        'Wildcard-Subscription-Available' => flag(Wildcard),
        'Subscription-Identifier-Available' => 1,
        'Shared-Subscription-Available' => flag(Shared)
    },
    %% MQTT 5.0 - 3.2.2.3.4:
    %% It is a Protocol Error to include Maximum QoS more than once,
    %% or to have a value other than 0 or 1. If the Maximum QoS is absent,
    %% the Client uses a Maximum QoS of 2.
    case MaxQoS =:= 2 of
        true -> NAckProps;
        _ -> NAckProps#{'Maximum-QoS' => MaxQoS}
    end;
enrich_connack_caps(AckProps, _Channel) ->
    AckProps.

%%--------------------------------------------------------------------
%% Enrich server keepalive

enrich_server_keepalive(AckProps, ?IS_MQTT_V5 = #channel{clientinfo = #{zone := Zone}}) ->
    case get_mqtt_conf(Zone, server_keepalive) of
        disabled -> AckProps;
        Keepalive -> AckProps#{'Server-Keep-Alive' => Keepalive}
    end;
enrich_server_keepalive(AckProps, _Channel) ->
    AckProps.

%%--------------------------------------------------------------------
%% Enrich response information

enrich_response_information(AckProps, #channel{
    conninfo = #{conn_props := ConnProps},
    clientinfo = #{zone := Zone}
}) ->
    case emqx_mqtt_props:get('Request-Response-Information', ConnProps, 0) of
        0 ->
            AckProps;
        1 ->
            AckProps#{
                'Response-Information' =>
                    case get_mqtt_conf(Zone, response_information, "") of
                        "" -> undefined;
                        RspInfo -> RspInfo
                    end
            }
    end.

%%--------------------------------------------------------------------
%% Enrich Assigned ClientId

enrich_assigned_clientid(AckProps, #channel{
    conninfo = ConnInfo,
    clientinfo = #{clientid := ClientId}
}) ->
    case maps:get(clientid, ConnInfo) of
        %% Original ClientId is null.
        <<>> ->
            AckProps#{'Assigned-Client-Identifier' => ClientId};
        _Origin ->
            AckProps
    end.

%%--------------------------------------------------------------------
%% Ensure connected

ensure_connected(
    Channel = #channel{
        conninfo = ConnInfo,
        clientinfo = ClientInfo
    }
) ->
    NConnInfo = ConnInfo#{connected_at => erlang:system_time(millisecond)},
    ok = run_hooks('client.connected', [ClientInfo, NConnInfo]),
    Channel#channel{
        conninfo = trim_conninfo(NConnInfo),
        conn_state = connected
    }.

trim_conninfo(ConnInfo) ->
    maps:without(
        [
            %% NOTE
            %% We remove the peercert because it duplicates what's stored in the socket,
            %% otherwise it wastes about 1KB per connection.
            %% Retrieve with: esockd_transport:peercert(Socket).
            %% Decode with APIs exported from esockd_peercert and esockd_ssl
            peercert
        ],
        ConnInfo
    ).

%%--------------------------------------------------------------------
%% Init Alias Maximum

init_alias_maximum(
    #mqtt_packet_connect{
        proto_ver = ?MQTT_PROTO_V5,
        properties = Properties
    },
    #{zone := Zone} = _ClientInfo
) ->
    #{
        outbound => emqx_mqtt_props:get('Topic-Alias-Maximum', Properties, 0),
        inbound => maps:get(max_topic_alias, emqx_mqtt_caps:get_caps(Zone))
    };
init_alias_maximum(_ConnPkt, _ClientInfo) ->
    undefined.

%%--------------------------------------------------------------------
%% Ensure Keepalive

%% MQTT 5
ensure_keepalive(#{'Server-Keep-Alive' := Interval}, Channel = #channel{conninfo = ConnInfo}) ->
    ensure_keepalive_timer(Interval, Channel#channel{conninfo = ConnInfo#{keepalive => Interval}});
%% MQTT 3,4
ensure_keepalive(_AckProps, Channel = #channel{conninfo = ConnInfo}) ->
    ensure_keepalive_timer(maps:get(keepalive, ConnInfo), Channel).

ensure_keepalive_timer(0, Channel) ->
    Channel;
ensure_keepalive_timer(disabled, Channel) ->
    Channel;
ensure_keepalive_timer(Interval, Channel = #channel{clientinfo = #{zone := Zone}}) ->
    Multiplier = get_mqtt_conf(Zone, keepalive_multiplier),
    RecvCnt = emqx_pd:get_counter(recv_pkt),
    Keepalive = emqx_keepalive:init(RecvCnt, round(timer:seconds(Interval) * Multiplier)),
    ensure_timer(keepalive, Channel#channel{keepalive = Keepalive}).

clear_keepalive(Channel = #channel{timers = Timers}) ->
    case maps:get(keepalive, Timers, undefined) of
        undefined ->
            Channel;
        TRef ->
            emqx_utils:cancel_timer(TRef),
            Channel#channel{timers = maps:without([keepalive], Timers)}
    end.
%%--------------------------------------------------------------------
%% Maybe Resume Session

maybe_resume_session(#channel{resuming = false}) ->
    ignore;
maybe_resume_session(#channel{
    session = Session,
    resuming = ReplayContext,
    clientinfo = ClientInfo
}) ->
    emqx_session:replay(ClientInfo, ReplayContext, Session).

%%--------------------------------------------------------------------
%% Maybe Shutdown the Channel

maybe_shutdown(Reason, _Intent = idle, Channel = #channel{conninfo = ConnInfo}) ->
    case maps:get(expiry_interval, ConnInfo) of
        ?EXPIRE_INTERVAL_INFINITE ->
            {ok, Channel};
        I when I > 0 ->
            {ok, ensure_timer(expire_session, I, Channel)};
        _ ->
            shutdown(Reason, Channel)
    end;
maybe_shutdown(Reason, _Intent = shutdown, Channel) ->
    shutdown(Reason, Channel).

%%--------------------------------------------------------------------
%% Parse Topic Filters

%% [{<<"$share/group/topic">>, _SubOpts = #{}} | _]
parse_raw_topic_filters(TopicFilters) ->
    lists:map(fun emqx_topic:parse/1, TopicFilters).

%%--------------------------------------------------------------------
%% Maybe & Ensure disconnected

ensure_disconnected(
    Reason,
    Channel = #channel{
        conninfo = ConnInfo,
        clientinfo = ClientInfo
    }
) ->
    NConnInfo = ConnInfo#{disconnected_at => erlang:system_time(millisecond)},
    ok = run_hooks('client.disconnected', [ClientInfo, Reason, NConnInfo]),
    ChanPid = self(),
    emqx_cm:mark_channel_disconnected(ChanPid),
    Channel#channel{conninfo = NConnInfo, conn_state = disconnected}.

session_disconnect(ClientInfo, ConnInfo, Session) when Session /= undefined ->
    emqx_session:disconnect(ClientInfo, ConnInfo, Session);
session_disconnect(_ClientInfo, _ConnInfo, undefined) ->
    {shutdown, undefined}.

%%--------------------------------------------------------------------
%% Maybe Publish will msg

maybe_publish_will_msg(Channel = #channel{will_msg = undefined}) ->
    Channel;
maybe_publish_will_msg(Channel = #channel{clientinfo = ClientInfo, will_msg = WillMsg}) ->
    case will_delay_interval(WillMsg) of
        0 ->
            ok = publish_will_msg(ClientInfo, WillMsg),
            Channel#channel{will_msg = undefined};
        I ->
            ensure_timer(will_message, timer:seconds(I), Channel)
    end.

will_delay_interval(WillMsg) ->
    maps:get(
        'Will-Delay-Interval',
        emqx_message:get_header(properties, WillMsg, #{}),
        0
    ).

publish_will_msg(
    ClientInfo = #{mountpoint := MountPoint},
    Msg = #message{topic = Topic}
) ->
    Action = authz_action(Msg),
    PublishingDisallowed = emqx_access_control:authorize(ClientInfo, Action, Topic) =/= allow,
    ClientBanned = emqx_banned:check(ClientInfo),
    case PublishingDisallowed orelse ClientBanned of
        true ->
            ?tp(
                warning,
                last_will_testament_publish_denied,
                #{
                    topic => Topic,
                    client_banned => ClientBanned,
                    publishing_disallowed => PublishingDisallowed
                }
            ),
            ok;
        false ->
            NMsg = emqx_mountpoint:mount(MountPoint, Msg),
            NMsg2 = NMsg#message{timestamp = erlang:system_time(millisecond)},
            _ = emqx_broker:publish(NMsg2),
            ok
    end.

%%--------------------------------------------------------------------
%% Disconnect Reason

disconnect_reason(?RC_SUCCESS) -> normal;
disconnect_reason(ReasonCode) -> emqx_reason_codes:name(ReasonCode).

reason_code(takenover) -> ?RC_SESSION_TAKEN_OVER;
reason_code(discarded) -> ?RC_SESSION_TAKEN_OVER.

%%--------------------------------------------------------------------
%% Helper functions
%%--------------------------------------------------------------------

-compile({inline, [run_hooks/2, run_hooks/3]}).
run_hooks(Name, Args) ->
    ok = emqx_metrics:inc(Name),
    emqx_hooks:run(Name, Args).

run_hooks(Name, Args, Acc) ->
    ok = emqx_metrics:inc(Name),
    emqx_hooks:run_fold(Name, Args, Acc).

-compile({inline, [find_alias/3, save_alias/4]}).

find_alias(_, _, undefined) -> error;
find_alias(inbound, AliasId, _TopicAliases = #{inbound := Aliases}) -> maps:find(AliasId, Aliases);
find_alias(outbound, Topic, _TopicAliases = #{outbound := Aliases}) -> maps:find(Topic, Aliases).

save_alias(_, _, _, undefined) ->
    false;
save_alias(inbound, AliasId, Topic, TopicAliases = #{inbound := Aliases}) ->
    NAliases = maps:put(AliasId, Topic, Aliases),
    TopicAliases#{inbound => NAliases};
save_alias(outbound, AliasId, Topic, TopicAliases = #{outbound := Aliases}) ->
    NAliases = maps:put(Topic, AliasId, Aliases),
    TopicAliases#{outbound => NAliases}.

-compile({inline, [reply/2, shutdown/2, shutdown/3, sp/1, flag/1]}).

reply(Reply, Channel) ->
    {reply, Reply, Channel}.

shutdown(success, Channel) ->
    shutdown(normal, Channel);
shutdown(Reason, Channel) ->
    {shutdown, Reason, Channel}.

shutdown(success, Reply, Channel) ->
    shutdown(normal, Reply, Channel);
shutdown(Reason, Reply, Channel) ->
    {shutdown, Reason, Reply, Channel}.

shutdown(success, Reply, Packet, Channel) ->
    shutdown(normal, Reply, Packet, Channel);
shutdown(Reason, Reply, Packet, Channel) ->
    {shutdown, Reason, Reply, Packet, Channel}.

%% process exits with {shutdown, #{shutdown_count := Kind}} will trigger
%% make the connection supervisor (esockd) keep a shutdown-counter groupd by Kind
shutdown_count(Kind, Reason) when is_map(Reason) ->
    Reason#{shutdown_count => Kind};
shutdown_count(Kind, Reason) ->
    #{shutdown_count => Kind, reason => Reason}.

%% mqtt v5 connected sessions
disconnect_and_shutdown(
    Reason,
    Reply,
    Channel =
        ?IS_MQTT_V5 =
        #channel{conn_state = ConnState}
) when
    ConnState =:= connected orelse ConnState =:= reauthenticating
->
    NChannel = ensure_disconnected(Reason, Channel),
    shutdown(Reason, Reply, ?DISCONNECT_PACKET(reason_code(Reason)), NChannel);
%% mqtt v3/v4 sessions, mqtt v5 other conn_state sessions
disconnect_and_shutdown(Reason, Reply, Channel) ->
    NChannel = ensure_disconnected(Reason, Channel),
    shutdown(Reason, Reply, NChannel).

-compile({inline, [sp/1, flag/1]}).
sp(true) -> 1;
sp(false) -> 0.

flag(true) -> 1;
flag(false) -> 0.

get_mqtt_conf(Zone, Key) ->
    emqx_config:get_zone_conf(Zone, [mqtt, Key]).

get_mqtt_conf(Zone, Key, Default) ->
    emqx_config:get_zone_conf(Zone, [mqtt, Key], Default).

%%--------------------------------------------------------------------
%% For CT tests
%%--------------------------------------------------------------------

set_field(Name, Value, Channel) ->
    Pos = emqx_utils:index_of(Name, record_info(fields, channel)),
    setelement(Pos + 1, Channel, Value).
