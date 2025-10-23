-module(grisp_updater_sink).


%--- Behaviour Definition ------------------------------------------------------

-doc "Notify the sink of a stream error; implementations should cleanup resources.".
-callback sink_error(StreamRef :: reference(), Params :: term(),
                     Reason :: term()) ->
    ok.
-doc "Deliver a data chunk. Return {abort, Reason} to stop the stream.".
-callback sink_data(StreamRef :: reference(), Params :: term(),
                    Data :: binary()) ->
    ok | {abort, Reason :: term()}.
-doc "Final data fragment and end-of-stream notification.".
-callback sink_done(StreamRef :: reference(), Params :: term(),
                    Data :: binary()) ->
    ok.
