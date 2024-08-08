-module(grisp_updater_storage).

-behavior(gen_server).


%--- Includes ------------------------------------------------------------------

-include_lib("kernel/include/logger.hrl").

-include("grisp_updater.hrl").


%--- Behaviour Definition ------------------------------------------------------

-callback storage_init(Opts :: map()) ->
    {ok, State :: term()} | {error, term()}.
-callback storage_prepare(State :: term(), Target :: target(),
                          ObjSize :: non_neg_integer()) ->
    ok | {error, term()}.
-callback storage_open(State :: term(), Device :: binary()) ->
    {ok, Descriptor :: term(), State :: term()} | {error, term()}.
-callback storage_write(State :: term(), Descriptor :: term(),
                Offset :: non_neg_integer(), Data :: iolist()) ->
    {ok, State :: term()} | {error, term()}.
-callback storage_read(State :: term(), Descriptor :: term(),
               Offset :: non_neg_integer(), Size :: non_neg_integer()) ->
    {ok, Data :: binary(), State :: term()} | {error, term()}.
-callback storage_close(State :: term(), Descriptor :: term()) ->
    {ok, State :: term()}.
-callback storage_terminate(State :: term(), Reason :: term()) ->
    ok.


%--- Exports -------------------------------------------------------------------

% API
-export([start_link/1]).
-export([digest/4]).
-export([prepare/2]).
-export([read/3]).
-export([write/3]).

% Callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).


%--- Records -------------------------------------------------------------------

-record(state, {
    storage :: undefined | {module(), term()}
}).


%--- Macros --------------------------------------------------------------------

%FIXME: Should probably not be infinity
-define(TIMEOUT, infinity).
-define(DIGEST_BLOCK_SIZE, 65536).


%--- API Functions -------------------------------------------------------------

start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

prepare(Target, ObjSize) ->
    gen_server:call(?MODULE, {prepare, Target, ObjSize}, ?TIMEOUT).

digest(Type, Device, Seek, Size) ->
    gen_server:call(?MODULE, {digest, Type, Device, Seek, Size}, ?TIMEOUT).

read(Device, Seek, Size) ->
    gen_server:call(?MODULE, {read, Device, Seek, Size}, ?TIMEOUT).

write(Device, Seek, Data) ->
    gen_server:call(?MODULE, {write, Device, Seek, Data}, ?TIMEOUT).


%--- Callbacks -----------------------------------------------------------------

init(#{backend := {Mod, Opts}}) when is_atom(Mod), is_map(Opts) ->
    ?LOG_INFO("Starting GRiSP updater's storage from ~p ...", [Mod]),
    storage_init(#state{}, Mod, Opts).

handle_call({prepare, Target, ObjSize}, _From, State) ->
    case storage_prepare(State, Target, ObjSize) of
        {ok, State2} -> {reply, ok, State2};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;
handle_call({digest, Type, Device, Seek, Size}, _From, State) ->
    case do_digest(State, Type, Device, Seek, Size) of
        {ok, Digest, State2} -> {reply, {ok, Digest}, State2};
        {error, Reason, State2} -> {reply, {error, Reason}, State2}
    end;
handle_call({read, Device, Seek, Size}, _From, State) ->
    case do_read(State, Device, Seek, Size) of
        {ok, Data, State2} -> {reply, {ok, Data}, State2};
        {error, Reason, State2} -> {reply, {error, Reason}, State2}
    end;
handle_call({write, Device, Seek, Data}, _From, State) ->
    case do_write(State, Device, Seek, Data) of
        {ok, State2} -> {reply, ok, State2};
        {error, Reason, State2} -> {reply, {error, Reason}, State2}
    end;
handle_call(Request, From, State) ->
    ?LOG_WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {reply, {error, unexpected_call}, State}.

handle_cast(Request, State) ->
    ?LOG_WARNING("Unexpected cast: ~p", [Request]),
    {noreply, State}.

handle_info(Info, State) ->
    ?LOG_WARNING("Unexpected messagge: ~p", [Info]),
    {noreply, State}.

terminate(Reason, State) ->
    storage_terminate(State, Reason),
    ok.


%--- Internal ------------------------------------------------------------------

do_digest(State, crc32, Device, Offset, Size) ->
    UpdateFun = fun erlang:crc32/2,
    FinalFun = fun(V) -> V end,
    case storage_open(State, Device) of
        {error, Reason} -> {error, Reason, State};
        {ok, Desc, State2} ->
            do_digest(State2, Desc, UpdateFun, FinalFun,
                      Offset, Size, ?DIGEST_BLOCK_SIZE, 0)
    end;
do_digest(State, T, Device, Offset, Size)
  when T =:= sha256; T =:= sha384; T =:= sha512 ->
    UpdateFun = fun crypto:hash_update/2,
    FinalFun = fun crypto:hash_final/1,
    case storage_open(State, Device) of
        {error, Reason} -> {error, Reason, State};
        {ok, Desc, State2} ->
            do_digest(State2, Desc, UpdateFun, FinalFun,
                      Offset, Size, ?DIGEST_BLOCK_SIZE, crypto:hash_init(T))
    end;
do_digest(State, T, _Device, _Offset, _Size) ->
    {error, {unsupported_digest, T}, State}.

do_digest(State, Desc, _UpdateFun, FinalFun, _Offset, 0, _BlockSize, H) ->
    Digest = FinalFun(H),
    {ok, State2} = storage_close(State, Desc),
    {ok, Digest, State2};
do_digest(State, Desc, UpdateFun, FinalFun, Offset, RemSize, BlockSize, H) ->
    ReadSize = min(RemSize, BlockSize),
    case storage_read(State, Desc, Offset, ReadSize) of
        {error, Reason} ->
            {ok, State2} = storage_close(State, Desc),
            {error, Reason, State2};
        {ok, Block, State2} when byte_size(Block) < ReadSize ->
            {ok, State3} = storage_close(State2, Desc),
            {error, eof, State3};
        {ok, Block, State2} ->
            H2 = UpdateFun(H, Block),
            do_digest(State2, Desc, UpdateFun, FinalFun, Offset + ReadSize,
                      RemSize - ReadSize, BlockSize, H2)
    end.

do_read(State, Device, Offset, Size) ->
    case storage_open(State, Device) of
        {error, Reason} ->
            {error, Reason, State};
        {ok, Desc, State2} ->
            case storage_read(State2, Desc, Offset, Size) of
                {error, Reason} ->
                    {ok, State3} = storage_close(State2, Desc),
                    {error, Reason, State3};
                {ok, Data, State3} ->
                    {ok, State4} = storage_close(State3, Desc),
                    {ok, Data, State4}
            end
    end.

do_write(State, Device, Offset, Data) ->
    case storage_open(State, Device) of
        {error, Reason} ->
            {error, Reason, State};
        {ok, Desc, State2} ->
            case storage_write(State2, Desc, Offset, Data) of
                {error, Reason} ->
                    {ok, State3} = storage_close(State2, Desc),
                    {error, Reason, State3};
                {ok, State3} ->
                    storage_close(State3, Desc)
            end
    end.


%--- Storage Callback Handling

storage_init(#state{storage = undefined} = State, Mod, Opts) ->
    case Mod:storage_init(Opts) of
        {error, _Reason} = Error -> Error;
        {ok, Sub} -> {ok, State#state{storage = {Mod, Sub}}}
    end.

storage_prepare(#state{storage = {Mod, Sub}} = State, Target, ObjSize) ->
    case Mod:storage_prepare(Sub, Target, ObjSize) of
        {error, _Reason} = Error -> Error;
        {ok, Sub2} ->
            {ok, State#state{storage = {Mod, Sub2}}}
    end.

storage_open(#state{storage = {Mod, Sub}} = State, Device) ->
    case Mod:storage_open(Sub, Device) of
        {error, _Reason} = Error -> Error;
        {ok, Descriptor, Sub2} ->
            {ok, Descriptor, State#state{storage = {Mod, Sub2}}}
    end.

storage_write(#state{storage = {Mod, Sub}} = State, Descriptor, Offset, Data) ->
    case Mod:storage_write(Sub, Descriptor, Offset, Data) of
        {error, _Reason} = Error -> Error;
        {ok, Sub2} -> {ok, State#state{storage = {Mod, Sub2}}}
    end.

storage_read(#state{storage = {Mod, Sub}} = State, Descriptor, Offset, Size) ->
    case Mod:storage_read(Sub, Descriptor, Offset, Size) of
        {error, _Reason} = Error -> Error;
        {ok, Data, Sub2} -> {ok, Data, State#state{storage = {Mod, Sub2}}}
    end.

storage_close(#state{storage = {Mod, Sub}} = State, Descriptor) ->
    {ok, Sub2} = Mod:storage_close(Sub, Descriptor),
    {ok, State#state{storage = {Mod, Sub2}}}.

storage_terminate(#state{storage = {Mod, Sub}}, Reason) ->
    Mod:terminate(Sub, Reason).
