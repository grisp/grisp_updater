-module(grisp_updater_loader).

-behavior(gen_server).
-behaviour(grisp_updater_sink).


%--- Includes ------------------------------------------------------------------

-include_lib("kernel/include/logger.hrl").

-include("grisp_updater.hrl").


%--- Exports -------------------------------------------------------------------

% API
-export([start_link/1]).
-export([schedule_load/3]).
-export([cancel_load/1]).
-export([abort/0]).

% Behaviour grisp_updater_sink Callbacks
-export([sink_error/3]).
-export([sink_data/3]).
-export([sink_done/3]).

% Behaviour gen_server Callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).


%--- Records -------------------------------------------------------------------


-record(pending, {
    url :: binary(),
    block :: #block{},
    target :: #target{},
    stream :: undefined | reference()
}).

-record(stream, {
    id :: non_neg_integer(),
    ref :: reference(),
    block_left :: undefined | non_neg_integer(),
    data_left :: non_neg_integer(),
    data_offset :: non_neg_integer(),
    block_hash :: undefined | term(),
    data_hash :: term(),
    inflater :: term()
}).

-record(state, {
    concurrency :: pos_integer(),
    pending = #{} :: #{non_neg_integer() => #pending{}},
    streams = #{} :: #{reference() => #stream{}},
    schedule = queue:new() :: queue:queue()
}).


%--- Macros --------------------------------------------------------------------

-define(DEFAULT_CONCURRENCY, 1).


%--- API Functions -------------------------------------------------------------

start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

schedule_load(Url, Block, Target) ->
    gen_server:cast(?MODULE, {schedule, Url, Block, Target}).

cancel_load(BlockId) ->
    gen_server:call(?MODULE, {cancel, BlockId}).

abort() ->
    gen_server:call(?MODULE, abort).


%--- Behaviour grisp_updater_sink Callbacks ------------------------------------

sink_error(StreamRef, Params, Reason) ->
    gen_server:cast(?MODULE, {sink_error, StreamRef, Params, Reason}).

sink_data(StreamRef, Params, Data) ->
    gen_server:cast(?MODULE, {sink_data, StreamRef, Params, Data}).

sink_done(StreamRef, Params, Data) ->
    gen_server:cast(?MODULE, {sink_done, StreamRef, Params, Data}).


%--- Behaviour gen_server Callbacks --------------------------------------------

init(Opts) ->
    ?LOG_INFO("Starting GRiSP block loader ..."),
    {ok, #state{
        concurrency = maps:get(concurrency, Opts, ?DEFAULT_CONCURRENCY)
    }}.

handle_call(abort, _From, State) ->
    {reply, ok, do_abort(State)};
handle_call({cancel, BlockId}, _From, State) ->
    {reply, ok, do_cancel(State, BlockId)};
handle_call(Request, From, State) ->
    ?LOG_WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {reply, {error, unexpected_call}, State}.
handle_cast({schedule, Url, Block, Target}, State) ->
    {noreply, do_schedule(State, Url, Block, Target)};
handle_cast({sink_error, StreamRef, Params, Reason}, State) ->
    {noreply, got_sink_error(State, StreamRef, Params, Reason)};
handle_cast({sink_data, StreamRef, Params, Data}, State) ->
    {noreply, got_sink_data(State, StreamRef, Params, Data)};
handle_cast({sink_done, StreamRef, Params, Data}, State) ->
    {noreply, got_sink_done(State, StreamRef, Params, Data)};
handle_cast(Request, State) ->
    ?LOG_WARNING("Unexpected cast: ~p", [Request]),
    {noreply, State}.

handle_info(Info, State) ->
    ?LOG_WARNING("Unexpected messagge: ~p", [Info]),
    {noreply, State}.


%--- Internal ------------------------------------------------------------------

block_path(#block{encoding = #raw_encoding{block_path = Path}}) -> Path;
block_path(#block{encoding = #gzip_encoding{block_path = Path}}) -> Path.

do_abort(State) ->
    cancel_pendings(State#state{schedule = queue:new()}).

do_cancel(State, BlockId) ->
    cancel_pending(State, BlockId).

do_schedule(#state{pending = PendMap, schedule = Sched} = State,
            Url, #block{id = Id} = Block, Target) ->
    ?LOG_DEBUG("Scheduling block ~b for streaming from ~s/~s",
               [Id, Url, block_path(Block)]),
    Pending = #pending{
        url = Url,
        block = Block,
        target = Target,
        stream = undefined
    },
    error = maps:find(Id, PendMap),
    PendMap2 = PendMap#{Id => Pending},
    Sched2 = queue:in(Id, Sched),
    start_streams(State#state{pending = PendMap2, schedule = Sched2}).

start_streams(#state{concurrency = Concurrency, streams = StreamMap,
                     schedule = Sched} = State) ->
    case maps:size(StreamMap) < Concurrency of
        false -> State;
        true ->
            case queue:out(Sched) of
                {empty, Sched2} ->
                    State#state{schedule = Sched2};
                {{value, Id}, Sched2} ->
                    State2 = State#state{schedule = Sched2},
                    start_streams(start_stream(State2, Id))
            end
    end.

block_ref(BaseUrl, Block) ->
    Path = block_path(Block),
    case uri_string:parse(Path) of
        #{scheme := _} -> {Path, <<>>};
        #{} -> {BaseUrl, Path}
    end.

start_stream(#state{pending = PendMap, streams = StreamMap} = State, Id) ->
    #{Id := #pending{url = Url, block = Block} = Pending} = PendMap,
    {BlockUrl, BlockPath} = block_ref(Url, Block),
    ?LOG_DEBUG("Start streaming block ~b from ~s/~s", [Id, BlockUrl, BlockPath]),
    case grisp_updater_source:stream(BlockUrl, BlockPath, ?MODULE, Id) of
        {error, Reason} ->
            grisp_updater_manager:loader_failed(Id, Reason),
            State#state{pending = maps:remove(Id, PendMap)};
        {ok, StreamRef} ->
            Pending2 = Pending#pending{stream = StreamRef},
            Stream = init_stream(Block, StreamRef),
            StreamMap2 = StreamMap#{StreamRef => Stream},
            PendMap2 = PendMap#{Id => Pending2},
            State#state{pending = PendMap2, streams = StreamMap2}
    end.

got_sink_error(#state{pending = PendMap, streams = StreamMap} = State,
               StreamRef, Id, Reason) ->
    %TODO: Figure out which errors are fatal and which are recoverable
    #{StreamRef := #stream{id = Id}} = StreamMap,
    #{Id := #pending{stream = StreamRef}} = PendMap,
    grisp_updater_manager:loader_failed(Id, Reason),
    start_streams(cancel_pending(State, Id)).

got_sink_data(#state{pending = PendMap, streams = StreamMap} = State,
              StreamRef, Id, Data) ->
    #{StreamRef := #stream{id = Id}} = StreamMap,
    #{Id := #pending{stream = StreamRef}} = PendMap,
    case got_data(State, StreamRef, Id, Data) of
        {error, Reason} ->
            %TODO: Figure out which errors are fatal and which are recoverable
            grisp_updater_manager:loader_failed(Id, Reason),
            start_streams(cancel_pending(State, Id));
        {ok, State2} ->
            State2
    end.

got_sink_done(#state{pending = PendMap, streams = StreamMap} = State,
              StreamRef, Id, Data) ->
    #{StreamRef := #stream{id = Id}} = StreamMap,
    #{Id := #pending{stream = StreamRef}} = PendMap,
    case got_data(State, StreamRef, Id, Data) of
        {error, Reason} ->
            %TODO: Figure out which errors are fatal and which are recoverable
            grisp_updater_manager:loader_failed(Id, Reason),
            start_streams(cancel_pending(State, Id));
        {ok, State2} ->
            start_streams(stream_terminated(State2, StreamRef))
    end.


got_data(#state{pending = PendMap, streams = StreamMap} = State,
         StreamRef, Id, BlockData) ->
    #{Id := #pending{stream = StreamRef} = Pending} = PendMap,
    #{StreamRef := #stream{id = Id} = Stream} = StreamMap,
    #pending{
        block = #block{id = Id, encoding = Encoding},
        stream = StreamRef
    } = Pending,
    case got_data(State, Pending, Stream, Encoding, BlockData) of
        {ok, Stream2, State2} ->
            StreamMap2 = StreamMap#{StreamRef := Stream2},
            {ok, State2#state{streams = StreamMap2}};
        {error, _Reason} = Error ->
            Error
    end.

got_data(State, Pending, Stream, #raw_encoding{}, BlockData) ->
    #pending{
        block = #block{data_offset = DataOffset},
        target = #target{device = Device, offset = DeviceOffset}
    } = Pending,
    #stream{
        data_left = DataLeft,
        data_offset = WriteOffset,
        data_hash = DataHash
    } = Stream,
    ChunkSize = byte_size(BlockData),
    case  ChunkSize =< DataLeft of
        false -> {error, block_too_large};
        true ->
            DataHash2 = crypto:hash_update(DataHash, BlockData),
            Seek = DeviceOffset + DataOffset + WriteOffset,
            case grisp_updater_storage:write(Device, Seek, BlockData) of
                {error, Reason} -> {error, {write_error, Reason}};
                ok ->
                    Stream2 = Stream#stream{
                        data_left = DataLeft - ChunkSize,
                        data_offset = WriteOffset + ChunkSize,
                        data_hash = DataHash2
                    },
                    {ok, Stream2, State}
            end
    end;
got_data(State, Pending, Stream, #gzip_encoding{}, BlockData) ->
    #pending{
        block = #block{data_offset = DataOffset},
        target = #target{device = Device, offset = DeviceOffset}
    } = Pending,
    #stream{
        block_left = BlockLeft,
        data_left = DataLeft,
        data_offset = WriteOffset,
        data_hash = DataHash,
        block_hash = BlockHash,
        inflater = Z
    } = Stream,
    ChunkSize = byte_size(BlockData),
    case  ChunkSize =< BlockLeft of
        false -> {error, encoded_block_too_large};
        true ->
            BlockHash2 = crypto:hash_update(BlockHash, BlockData),
            try zlib:inflate(Z, BlockData) of
                Data ->
                    InflatedChuckSize = iolist_size(Data),
                    case InflatedChuckSize =< DataLeft of
                        false -> {error, decoded_block_too_large};
                        true ->
                            DataHash2 = crypto:hash_update(DataHash, Data),
                            Seek = DeviceOffset + DataOffset + WriteOffset,
                            case grisp_updater_storage:write(Device, Seek, Data) of
                                {error, Reason} -> {error, {write_error, Reason}};
                                ok ->
                                    Stream2 = Stream#stream{
                                        block_left = BlockLeft - ChunkSize,
                                        data_left = DataLeft - InflatedChuckSize,
                                        data_offset = WriteOffset + InflatedChuckSize,
                                        data_hash = DataHash2,
                                        block_hash = BlockHash2
                                    },
                                    {ok, Stream2, State}
                            end
                    end
            catch
                error:Reason -> {error, {deflate_error, Reason}}
            end
    end.

stream_terminated(#state{pending = PendMap, streams = StreamMap} = State,
                  StreamRef) ->
    #{StreamRef := #stream{id = Id} = Stream} = StreamMap,
    #{Id := #pending{stream = StreamRef, block = Block}} = PendMap,
    #block{id = Id, encoding = Encoding} = Block,
    State2 = stream_terminated(State, Block, Stream, Encoding),
    cleanup_stream(Stream),
    State2#state{pending = maps:remove(Id, PendMap),
                 streams = maps:remove(StreamRef, StreamMap)}.

stream_terminated(State, Block, Stream, #raw_encoding{}) ->
    #block{id = Id, data_hash_data = ExpDataHash} = Block,
    #stream{data_left = DataLeft, data_hash = DataHash} = Stream,
    GotDataHash = crypto:hash_final(DataHash),
    case {DataLeft, GotDataHash} of
        {0, ExpDataHash} ->
           grisp_updater_manager:loader_done(Id);
        {V, _} when V =:= 0 ->
            grisp_updater_manager:loader_failed(Id, data_size_mismatch);
        {_, H} when H =/= ExpDataHash ->
            grisp_updater_manager:loader_failed(Id, data_hash_mismatch)
    end,
    State;
stream_terminated(State, Block, Stream, #gzip_encoding{}) ->
    #block{
        id = Id,
        data_hash_data = ExpDataHash,
        encoding = #gzip_encoding{
            block_hash_data = ExpBlockHash
        }
    } = Block,
    #stream{
        block_left = BlockLeft,
        data_left = DataLeft,
        data_hash = DataHash,
        block_hash = BlockHash
    } = Stream,
    GotDataHash = crypto:hash_final(DataHash),
    GotBlockHash = crypto:hash_final(BlockHash),
    case {BlockLeft, DataLeft, GotBlockHash, GotDataHash} of
        {0, 0, ExpBlockHash, ExpDataHash} ->
           grisp_updater_manager:loader_done(Id);
        {V, _, _, _} when V =:= 0 ->
            grisp_updater_manager:loader_failed(Id, block_size_mismatch);
        {_, V, _, _} when V =:= 0 ->
            grisp_updater_manager:loader_failed(Id, data_size_mismatch);
        {_, _, H, _} when H =/= ExpBlockHash ->
            grisp_updater_manager:loader_failed(Id, block_hash_mismatch);
        {_, _, _, H} when H =/= ExpDataHash ->
            grisp_updater_manager:loader_failed(Id, data_hash_mismatch)
    end,
    State.

init_stream(#block{encoding = #raw_encoding{}} = Block, StreamRef) ->
    #block{
        id = Id,
        data_size = DataSize,
        data_hash_type = DataHashType
    } = Block,
    #stream{
        id = Id,
        ref = StreamRef,
        data_left = DataSize,
        data_offset = 0,
        data_hash = crypto:hash_init(DataHashType)
    };
init_stream(#block{encoding = #gzip_encoding{}} = Block, StreamRef) ->
    #block{
        id = Id,
        data_size = DataSize,
        data_hash_type = DataHashType,
        encoding = #gzip_encoding{
            block_size = BlockSize,
            block_hash_type = BlockHashType
        }
    } = Block,
    Z = zlib:open(),
    zlib:inflateInit(Z, 16 + 15, reset),
    #stream{
        id = Id,
        ref = StreamRef,
        block_left = BlockSize,
        data_left = DataSize,
        data_offset = 0,
        data_hash = crypto:hash_init(DataHashType),
        block_hash = crypto:hash_init(BlockHashType),
        inflater = Z
    }.

cancel_pendings(#state{pending = PendMap} = State) ->
    lists:foldl(fun
        (#pending{stream = undefined}, S) -> S;
        (#pending{stream = StreamRef}, S) ->
            cancel_stream(S, StreamRef)
    end, State#state{pending = #{}}, maps:values(PendMap)).

cancel_pending(#state{pending = PendMap} = State, BlockId) ->
    case maps:take(BlockId, PendMap) of
        error -> State;
        {#pending{stream = undefined}, PendMap2} ->
            State#state{pending = PendMap2};
        {#pending{stream = StreamRef}, PendMap2} ->
            cancel_stream(State#state{pending = PendMap2}, StreamRef)
    end.

cancel_stream(#state{streams = StreamMap} = State, StreamRef) ->
    case maps:take(StreamRef, StreamMap) of
        error -> State;
        {Stream, StreamMap2} ->
            grisp_updater_source:cancel(StreamRef),
            cleanup_stream(Stream),
            State#state{streams = StreamMap2}
    end.

cleanup_stream(#stream{inflater = undefined}) ->
    ok;
cleanup_stream(#stream{inflater = Z}) ->
    catch zlib:inflateEnd(Z),
    catch zlib:close(Z),
    ok.
