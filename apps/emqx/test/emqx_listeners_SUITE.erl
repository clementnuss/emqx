%%--------------------------------------------------------------------
%% Copyright (c) 2018-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_listeners_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/emqx_schema.hrl").
-include_lib("emqx/include/asserts.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(SERVER_KEY_PASSWORD, "sErve7r8Key$!").

all() -> emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    generate_tls_certs(Config),
    WorkDir = emqx_cth_suite:work_dir(Config),
    Apps = emqx_cth_suite:start([quicer, emqx], #{work_dir => WorkDir}),
    [{apps, Apps} | Config].

end_per_suite(Config) ->
    ok = emqx_cth_suite:stop(?config(apps, Config)).

init_per_testcase(Case, Config) when
    Case =:= t_start_stop_listeners;
    Case =:= t_restart_listeners;
    Case =:= t_restart_listeners_with_hibernate_after_disabled
->
    ok = emqx_listeners:stop(),
    Config;
init_per_testcase(_, Config) ->
    ok = emqx_listeners:start(),
    Config.

end_per_testcase(_, _Config) ->
    ok.

t_start_stop_listeners(_) ->
    ok = emqx_listeners:start(),
    ?assertException(error, _, emqx_listeners:start_listener(ws, {"127.0.0.1", 8083}, #{})),
    ok = emqx_listeners:stop().

t_restart_listeners(_) ->
    ok = emqx_listeners:start(),
    ok = emqx_listeners:stop(),
    ok = emqx_listeners:restart(),
    ok = emqx_listeners:stop().

t_restart_listeners_with_hibernate_after_disabled(_Config) ->
    OldLConf = emqx_config:get([listeners]),
    maps:foreach(
        fun(LType, Listeners) ->
            maps:foreach(
                fun(Name, Opts) ->
                    case maps:is_key(ssl_options, Opts) of
                        true ->
                            emqx_config:put(
                                [
                                    listeners,
                                    LType,
                                    Name,
                                    ssl_options,
                                    hibernate_after
                                ],
                                undefined
                            );
                        _ ->
                            skip
                    end
                end,
                Listeners
            )
        end,
        OldLConf
    ),
    ok = emqx_listeners:start(),
    ok = emqx_listeners:stop(),
    ok = emqx_listeners:restart(),
    ok = emqx_listeners:stop(),
    emqx_config:put([listeners], OldLConf).

t_max_conns_tcp(_Config) ->
    %% Note: Using a string representation for the bind address like
    %% "127.0.0.1" does not work
    Port = emqx_common_test_helpers:select_free_port(tcp),
    Conf = #{
        <<"bind">> => format_bind({"127.0.0.1", Port}),
        <<"max_connections">> => 4321,
        <<"limiter">> => #{}
    },
    with_listener(tcp, maxconns, Conf, fun() ->
        ?assertEqual(
            4321,
            emqx_listeners:max_conns('tcp:maxconns', {{127, 0, 0, 1}, Port})
        )
    end).

t_current_conns_tcp(_Config) ->
    Port = emqx_common_test_helpers:select_free_port(tcp),
    Conf = #{
        <<"bind">> => format_bind({"127.0.0.1", Port}),
        <<"max_connections">> => 42,
        <<"limiter">> => #{}
    },
    with_listener(tcp, curconns, Conf, fun() ->
        ?assertEqual(
            0,
            emqx_listeners:current_conns('tcp:curconns', {{127, 0, 0, 1}, Port})
        )
    end).

t_wss_conn(Config) ->
    PrivDir = ?config(priv_dir, Config),
    Port = emqx_common_test_helpers:select_free_port(ssl),
    Conf = #{
        <<"bind">> => format_bind({"127.0.0.1", Port}),
        <<"limiter">> => #{},
        <<"ssl_options">> => #{
            <<"cacertfile">> => filename:join(PrivDir, "ca.pem"),
            <<"certfile">> => filename:join(PrivDir, "server.pem"),
            <<"keyfile">> => filename:join(PrivDir, "server.key")
        }
    },
    with_listener(wss, wssconn, Conf, fun() ->
        {ok, Socket} = ssl:connect({127, 0, 0, 1}, Port, [{verify, verify_none}], 1000),
        ok = ssl:close(Socket)
    end).

t_quic_conn(Config) ->
    PrivDir = ?config(priv_dir, Config),
    Port = emqx_common_test_helpers:select_free_port(quic),
    Conf = #{
        <<"bind">> => format_bind({"127.0.0.1", Port}),
        <<"ssl_options">> => #{
            <<"password">> => ?SERVER_KEY_PASSWORD,
            <<"certfile">> => filename:join(PrivDir, "server-password.pem"),
            <<"cacertfile">> => filename:join(PrivDir, "ca.pem"),
            <<"keyfile">> => filename:join(PrivDir, "server-password.key")
        }
    },
    with_listener(quic, ?FUNCTION_NAME, Conf, fun() ->
        {ok, Conn} = quicer:connect(
            {127, 0, 0, 1},
            Port,
            [
                {verify, verify_none},
                {alpn, ["mqtt"]}
            ],
            1000
        ),
        ok = quicer:close_connection(Conn)
    end).

t_ssl_password_cert(Config) ->
    PrivDir = ?config(priv_dir, Config),
    Port = emqx_common_test_helpers:select_free_port(ssl),
    SSLOptsPWD = #{
        <<"password">> => ?SERVER_KEY_PASSWORD,
        <<"certfile">> => filename:join(PrivDir, "server-password.pem"),
        <<"cacertfile">> => filename:join(PrivDir, "ca.pem"),
        <<"keyfile">> => filename:join(PrivDir, "server-password.key")
    },
    LConf = #{
        <<"enable">> => true,
        <<"bind">> => format_bind({{127, 0, 0, 1}, Port}),
        <<"ssl_options">> => SSLOptsPWD
    },
    with_listener(ssl, ?FUNCTION_NAME, LConf, fun() ->
        {ok, SSLSocket} = ssl:connect("127.0.0.1", Port, [{verify, verify_none}]),
        ssl:close(SSLSocket)
    end).

t_ssl_update_opts(Config) ->
    PrivDir = ?config(priv_dir, Config),
    Host = "127.0.0.1",
    Port = emqx_common_test_helpers:select_free_port(ssl),
    Conf = #{
        <<"enable">> => true,
        <<"bind">> => format_bind({Host, Port}),
        <<"ssl_options">> => #{
            <<"cacertfile">> => filename:join(PrivDir, "ca.pem"),
            <<"password">> => ?SERVER_KEY_PASSWORD,
            <<"certfile">> => filename:join(PrivDir, "server-password.pem"),
            <<"keyfile">> => filename:join(PrivDir, "server-password.key"),
            <<"verify">> => verify_none
        }
    },
    ClientSSLOpts = [
        {verify, verify_peer},
        {customize_hostname_check, [{match_fun, fun(_, _) -> true end}]}
    ],
    with_listener(ssl, updated, Conf, fun() ->
        %% Client connects successfully.
        C1 = emqtt_connect_ssl(Host, Port, [
            {cacertfile, filename:join(PrivDir, "ca.pem")} | ClientSSLOpts
        ]),

        %% Change the listener SSL configuration: another set of cert/key files.
        {ok, _} = emqx:update_config(
            [listeners, ssl, updated],
            {update, #{
                <<"ssl_options">> => #{
                    <<"cacertfile">> => filename:join(PrivDir, "ca-next.pem"),
                    <<"certfile">> => filename:join(PrivDir, "server.pem"),
                    <<"keyfile">> => filename:join(PrivDir, "server.key")
                }
            }}
        ),

        %% Unable to connect with old SSL options, server's cert is signed by another CA.
        ?assertError(
            {tls_alert, {unknown_ca, _}},
            emqtt_connect_ssl(Host, Port, [
                {cacertfile, filename:join(PrivDir, "ca.pem")} | ClientSSLOpts
            ])
        ),

        C2 = emqtt_connect_ssl(Host, Port, [
            {cacertfile, filename:join(PrivDir, "ca-next.pem")} | ClientSSLOpts
        ]),

        %% Change the listener SSL configuration: require peer certificate.
        {ok, _} = emqx:update_config(
            [listeners, ssl, updated],
            {update, #{
                <<"ssl_options">> => #{
                    <<"verify">> => verify_peer,
                    <<"fail_if_no_peer_cert">> => true
                }
            }}
        ),

        %% Unable to connect with old SSL options, certificate is now required.
        ?assertExceptionOneOf(
            {error, {ssl_error, _Socket, {tls_alert, {certificate_required, _}}}},
            {error, closed},
            emqtt_connect_ssl(Host, Port, [
                {cacertfile, filename:join(PrivDir, "ca-next.pem")} | ClientSSLOpts
            ])
        ),

        C3 = emqtt_connect_ssl(Host, Port, [
            {cacertfile, filename:join(PrivDir, "ca-next.pem")},
            {certfile, filename:join(PrivDir, "client.pem")},
            {keyfile, filename:join(PrivDir, "client.key")}
            | ClientSSLOpts
        ]),

        %% Both pre- and post-update clients should be alive.
        ?assertEqual(pong, emqtt:ping(C1)),
        ?assertEqual(pong, emqtt:ping(C2)),
        ?assertEqual(pong, emqtt:ping(C3)),

        ok = emqtt:stop(C1),
        ok = emqtt:stop(C2),
        ok = emqtt:stop(C3)
    end).

t_wss_update_opts(Config) ->
    PrivDir = ?config(priv_dir, Config),
    Host = "127.0.0.1",
    Port = emqx_common_test_helpers:select_free_port(ssl),
    Conf = #{
        <<"enable">> => true,
        <<"bind">> => format_bind({Host, Port}),
        <<"ssl_options">> => #{
            <<"cacertfile">> => filename:join(PrivDir, "ca.pem"),
            <<"certfile">> => filename:join(PrivDir, "server-password.pem"),
            <<"keyfile">> => filename:join(PrivDir, "server-password.key"),
            <<"password">> => ?SERVER_KEY_PASSWORD,
            <<"verify">> => verify_none
        }
    },
    ClientSSLOpts = [
        {verify, verify_peer},
        {customize_hostname_check, [{match_fun, fun(_, _) -> true end}]}
    ],
    with_listener(wss, updated, Conf, fun() ->
        %% Start a client.
        C1 = emqtt_connect_wss(Host, Port, [
            {cacertfile, filename:join(PrivDir, "ca.pem")}
            | ClientSSLOpts
        ]),

        %% Change the listener SSL configuration.
        %% 1. Another set of (password protected) cert/key files.
        %% 2. Require peer certificate.
        {ok, _} = emqx:update_config(
            [listeners, wss, updated],
            {update, #{
                <<"ssl_options">> => #{
                    <<"cacertfile">> => filename:join(PrivDir, "ca-next.pem"),
                    <<"certfile">> => filename:join(PrivDir, "server.pem"),
                    <<"keyfile">> => filename:join(PrivDir, "server.key")
                }
            }}
        ),

        %% Unable to connect with old SSL options, server's cert is signed by another CA.
        %% Due to a bug `emqtt` exits with `badmatch` in this case.
        ?assertExit(
            _Badmatch,
            emqtt_connect_wss(Host, Port, ClientSSLOpts)
        ),

        C2 = emqtt_connect_wss(Host, Port, [
            {cacertfile, filename:join(PrivDir, "ca-next.pem")}
            | ClientSSLOpts
        ]),

        %% Change the listener SSL configuration: require peer certificate.
        {ok, _} = emqx:update_config(
            [listeners, wss, updated],
            {update, #{
                <<"ssl_options">> => #{
                    <<"verify">> => verify_peer,
                    <<"fail_if_no_peer_cert">> => true
                }
            }}
        ),

        %% Unable to connect with old SSL options, certificate is now required.
        %% Due to a bug `emqtt` does not instantly report that socket was closed.
        ?assertError(
            timeout,
            emqtt_connect_wss(Host, Port, [
                {cacertfile, filename:join(PrivDir, "ca-next.pem")}
                | ClientSSLOpts
            ])
        ),

        C3 = emqtt_connect_wss(Host, Port, [
            {cacertfile, filename:join(PrivDir, "ca-next.pem")},
            {certfile, filename:join(PrivDir, "client.pem")},
            {keyfile, filename:join(PrivDir, "client.key")}
            | ClientSSLOpts
        ]),

        %% Both pre- and post-update clients should be alive.
        ?assertEqual(pong, emqtt:ping(C1)),
        ?assertEqual(pong, emqtt:ping(C2)),
        ?assertEqual(pong, emqtt:ping(C3)),

        ok = emqtt:stop(C1),
        ok = emqtt:stop(C2),
        ok = emqtt:stop(C3)
    end).

with_listener(Type, Name, Config, Then) ->
    {ok, _} = emqx:update_config([listeners, Type, Name], {create, Config}),
    try
        Then()
    after
        emqx:update_config([listeners, Type, Name], ?TOMBSTONE_CONFIG_CHANGE_REQ)
    end.

emqtt_connect_ssl(Host, Port, SSLOpts) ->
    emqtt_connect(fun emqtt:connect/1, #{
        hosts => [{Host, Port}],
        connect_timeout => 1,
        ssl => true,
        ssl_opts => SSLOpts
    }).

emqtt_connect_wss(Host, Port, SSLOpts) ->
    emqtt_connect(fun emqtt:ws_connect/1, #{
        hosts => [{Host, Port}],
        connect_timeout => 1,
        ws_transport_options => [
            {protocols, [http]},
            {transport, tls},
            {tls_opts, SSLOpts}
        ]
    }).

emqtt_connect(Connect, Opts) ->
    case emqtt:start_link(Opts) of
        {ok, Client} ->
            true = erlang:unlink(Client),
            case Connect(Client) of
                {ok, _} -> Client;
                {error, Reason} -> error(Reason, [Opts])
            end;
        {error, Reason} ->
            error(Reason, [Opts])
    end.

t_format_bind(_) ->
    ?assertEqual(
        ":1883",
        lists:flatten(emqx_listeners:format_bind(1883))
    ),
    ?assertEqual(
        "0.0.0.0:1883",
        lists:flatten(emqx_listeners:format_bind({{0, 0, 0, 0}, 1883}))
    ),
    ?assertEqual(
        "[::]:1883",
        lists:flatten(emqx_listeners:format_bind({{0, 0, 0, 0, 0, 0, 0, 0}, 1883}))
    ),
    ?assertEqual(
        "127.0.0.1:1883",
        lists:flatten(emqx_listeners:format_bind({{127, 0, 0, 1}, 1883}))
    ),
    ?assertEqual(
        ":1883",
        lists:flatten(emqx_listeners:format_bind("1883"))
    ),
    ?assertEqual(
        ":1883",
        lists:flatten(emqx_listeners:format_bind(":1883"))
    ).

generate_tls_certs(Config) ->
    PrivDir = ?config(priv_dir, Config),
    emqx_common_test_helpers:gen_ca(PrivDir, "ca"),
    emqx_common_test_helpers:gen_ca(PrivDir, "ca-next"),
    emqx_common_test_helpers:gen_host_cert("server", "ca-next", PrivDir, #{}),
    emqx_common_test_helpers:gen_host_cert("client", "ca-next", PrivDir, #{}),
    emqx_common_test_helpers:gen_host_cert("server-password", "ca", PrivDir, #{
        password => ?SERVER_KEY_PASSWORD
    }).

format_bind(Bind) ->
    iolist_to_binary(emqx_listeners:format_bind(Bind)).
