-module(grisp_updater_grisp2).

-behaviour(grisp_updater_system).


%--- Includes ------------------------------------------------------------------

-include_lib("kernel/include/logger.hrl").


%--- Exports -------------------------------------------------------------------

% Behaviour grisp_updater_source callbacks
-export([system_init/1]).
-export([system_device/1]).
-export([system_get_active/1]).
-export([system_set_updated/2]).
-export([system_validate/1]).
-export([system_terminate/2]).


%--- Behaviour grisp_updater_source Callback -----------------------------------

system_init(_Opts) ->
    ?LOG_INFO("Initializing GRiSP2 update system interface", []),
    {error, not_implemnted}.

system_device(_State) ->
    <<"/dev/null">>.

system_get_active(_State) ->
    {0, true}.

system_set_updated(_State, _SystemId) ->
    {error, not_implemnted}.

system_validate(_State) ->
    {error, not_implemnted}.

system_terminate(_State, _Reason) ->
    ?LOG_INFO("Terminating GRiSP update system interface", []),
    ok.
