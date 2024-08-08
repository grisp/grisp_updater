-module(grisp_updater).


%--- Exports -------------------------------------------------------------------

% API functions
-export([info/0, info/1]).
-export([update/1, update/2]).
-export([start/3, start/4]).
-export([status/0]).
-export([cancel/0]).
-export([validate/0]).


%--- API Functions -------------------------------------------------------------

info() ->
    grisp_updater_manager:get_info().

info(Url) ->
    grisp_updater_manager:get_info(Url).

update(Url) ->
    grisp_updater_manager:update(Url, #{}).

update(Url, Opts) ->
    grisp_updater_manager:update(Url, Opts).

start(Url, Callbacks, Params) ->
    start(Url, Callbacks, Params, #{}).

start(Url, Callbacks, Params, Opts) ->
    grisp_updater_manager:start_update(Url, Callbacks, Params, Opts).

status() ->
    grisp_updater_manager:get_status().

cancel() ->
    grisp_updater_manager:cancel_update().

validate() ->
    grisp_updater_manager:validate().


%--- Internal Functions --------------------------------------------------------

