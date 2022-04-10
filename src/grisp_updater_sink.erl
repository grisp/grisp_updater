-module(grisp_updater_sink).


%--- Behaviour Definition ------------------------------------------------------

-callback sink_error(StreamRef :: reference(), Params :: term(),
                     Reason :: term()) ->
    ok.
-callback sink_data(StreamRef :: reference(), Params :: term(),
                    Data :: binary()) ->
    ok | {abort, Reason :: term()}.
-callback sink_done(StreamRef :: reference(), Params :: term(),
                    Data :: binary()) ->
    ok.
