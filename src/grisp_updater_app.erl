-module(grisp_updater_app).

-behaviour(application).


%--- Exports -------------------------------------------------------------------

% API functions

% Behaviour application callbacks
-export([start/2]).
-export([stop/1]).


%--- API Functions -------------------------------------------------------------


%--- Behaviour application Callbacks -------------------------------------------

start(_StartType, _StartArgs) ->
    grisp_updater_sup:start_link().

stop(_State) ->
    ok.
