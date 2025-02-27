-module(oidcc_cowboy_authorize).

-feature(maybe_expr, enable).

-include("internal/doc.hrl").
?MODULEDOC("""
Cowboy Oidcc Authorization Handler

## Usage

```erlang
OidccCowboyOpts = #{
    provider => config_provider_gen_server_name,
    client_id => <<"client_id">>,
    client_secret => <<"client_secret">>,
    redirect_uri => "http://localhost/oidc/return"
},
OidccCowboyCallbackOpts = maps:merge(OidccCowboyOpts, #{
    %% ...
}),
Dispatch = cowboy_router:compile([
    {'_', [
        {"/", oidcc_cowboy_authorize, OidccCowboyOpts},
        {"/oidc/return", oidcc_cowboy_callback, OidccCowboyCallbackOpts}
    ]}
]),
{ok, _} = cowboy:start_clear(http, [{port, 8080}], #{
    env => #{dispatch => Dispatch}
})
```
""").
?MODULEDOC(#{since => <<"2.0.0">>}).

-behaviour(cowboy_handler).

-export([init/2]).
-export([terminate/3]).

-export_type([error/0]).
-export_type([opts/0]).

?DOC(#{since => <<"2.0.0">>}).
-type error() :: oidcc_client_context:error() | oidcc_authorization:error().

?DOC("""
Configure authorization redirection

See https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest

## Parameters

- `provider` - name of the running `m:oidcc_provider_configuration_worker`
- `client_id` - Client ID
- `client_secret` - Client Secret
- `redirect_uri` - redirect target after authorization is completed
- `scopes` - list of scopes to request (defaults to `[<<"openid">>]`)
- `url_extension` - add custom query parameters to the authorization url
- `handle_failure` - handler to react to errors (render response etc.)

## Query Parameters

- `state` - supplied as state parameter to the OpenID Provider
""").
?DOC(#{since => <<"2.0.0">>}).
-type opts() :: #{
    provider := gen_server:server_ref(),
    client_id := binary(),
    client_secret := binary(),
    redirect_uri := uri_string:uri_string(),
    scopes => oidcc_scope:scopes(),
    url_extension => oidcc_http_util:query_params(),
    handle_failure => fun((Req :: cowboy_req:req(), Reason :: error()) -> cowboy_req:req())
}.

?DOC(false).
-spec init(Req, Opts) -> {ok, Req, State} when
    Req :: cowboy_req:req(), Opts :: opts(), State :: nil.
init(Req, Opts) ->
    QueryList = cowboy_req:parse_qs(Req),

    Headers = cowboy_req:headers(Req),

    {PeerIp, _Port} = cowboy_req:peer(Req),
    Useragent = maps:get(<<"user-agent">>, Headers, undefined),

    ProviderId = maps:get(provider, Opts),
    ClientId = maps:get(client_id, Opts),
    ClientSecret = maps:get(client_secret, Opts),

    HandleFailure = maps:get(handle_failure, Opts, fun(FailureReq, _Reason) ->
        cowboy_req:reply(500, #{}, <<"internal error">>, FailureReq)
    end),

    Nonce = generate_random_length_string(128),
    State = proplists:get_value(<<"state">>, QueryList, undefined),
    PkceVerifier = generate_random_length_string(128),

    AuthorizationOpts = maps:merge(
        #{nonce => Nonce, state => State, pkce_verifier => PkceVerifier},
        maps:with([redirect_uri, scopes, state, pkce, url_extension, preferred_auth_methods], Opts)
    ),

    maybe
        {ok, Req1} ?=
            cowboy_session:set(
                oidcc_cowboy,
                #{
                    nonce => Nonce,
                    peer_ip => PeerIp,
                    useragent => Useragent,
                    pkce_verifier => PkceVerifier
                },
                Req
            ),
        {ok, Url} ?=
            oidcc:create_redirect_url(ProviderId, ClientId, ClientSecret, AuthorizationOpts),
        Req2 = cowboy_req:reply(302, #{<<"location">> => Url}, <<>>, Req1),
        {ok, Req2, nil}
    else
        {error, Reason} ->
            {ok, HandleFailure(Req, Reason), nil}
    end.

-spec generate_random_length_string(Length) -> binary() when Length :: pos_integer().
generate_random_length_string(Length) ->
    %% Base64 increases size by 1/3
    RawLength = trunc(Length / 4 * 3),
    RandomBytes = crypto:strong_rand_bytes(RawLength),
    base64:encode(RandomBytes, #{mode => urlsafe, padding => false}).

?DOC(false).
terminate(_Reason, _Req, _State) ->
    ok.
