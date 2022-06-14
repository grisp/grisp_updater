-module(grisp_updater_manifest).

%--- Includes ------------------------------------------------------------------

-include("grisp_updater.hrl").


%--- Exports -------------------------------------------------------------------

% API Functions
-export([parse_data/2]).
-export([parse_term/2]).


%--- API Functions -------------------------------------------------------------

parse_data(Data, Opts) ->
    try
        Encoding = case epp:read_encoding_from_binary(Data) of
            none -> latin1;
            E -> E
        end,
        case unicode:characters_to_list(Data, Encoding) of
            {error, _, _} -> {error, bad_manifest};
            {incomplete, _, _} -> {error, bad_manifest};
            Text ->
                case erl_scan:string(Text) of
                    {error, _, _} -> {error, bad_manifest};
                    {ok, Tokens, _} ->
                        case erl_parse:parse_term(Tokens) of
                            {error, _} -> {error, bad_manifest};
                            {ok, [_|_] = Term} ->
                                {ok, parse_manifest(Term, [], Opts)}
                        end
                end
        end
    catch
        throw:Reason -> {error, Reason}
    end.

parse_term(Term, Opts) ->
    try
        {ok, parse_manifest(Term, [], Opts)}
    catch
        throw:Reason -> {error, Reason}
    end.


%--- Internal Functions --------------------------------------------------------

parse_manifest(Props, Stack, Opts) ->
    Format = check_format(Props, Opts),
    Structure = parse_structure(get_opttup(Props, Stack, structure),
                                [structure | Stack], Opts),
    {Objects, C, D, B} = parse_objects(get_reqlist(Props, Stack, objects), 0,
                                       [objects | Stack], Opts, [], 0, 0, 0),
    #manifest{
        format = Format,
        product = get_reqbin(Props, Stack, product),
        version = get_reqver(Props, Stack, version),
        desc = get_optbin(Props, Stack, description),
        architecture = get_reqbin(Props, Stack, architecture),
        structure = Structure,
        objects = Objects,
        block_count = C,
        data_size = D,
        block_size = B
    }.

check_format(Props, _Opts) ->
    case proplists:get_value(format, Props) of
        undefined -> throw({bad_manifest, unsupported_format});
        {1, 0, 0} = Result -> Result;
        _ -> throw({bad_manifest, unsupported_format})
    end.

parse_structure({mbr, [_|_] = Def}, Stack, Opts) ->
    Stack2 = [mbr | Stack],
    PartitionDefs = get_reqlist(Def, Stack2, partitions),
    Partitions = parse_mbr_partitions(PartitionDefs, 0,
                                      [partitions | Stack2], Opts, []),
    #mbr{
        sector_size = get_reqint(Def, Stack2, sector_size),
        partitions = Partitions
    };
parse_structure({gpt, [_|_] = Def}, Stack, Opts) ->
    Stack2 = [gpt | Stack],
    PartitionDefs = get_reqlist(Def, Stack2, partitions),
    Partitions = parse_gpt_partitions(PartitionDefs, 0,
                                      [partitions | Stack2], Opts, []),
    #gpt{
        sector_size = get_reqint(Def, Stack2, sector_size),
        partitions = Partitions
    };
parse_structure(undefined, _Stack, _Opts) ->
    undefined;
parse_structure({T, _}, Stack, _Opts) ->
    throw({bad_manifest, {bad_structure_type, lists:reverse(Stack), T}});
parse_structure(_, Stack, _Opts) ->
    throw({bad_manifest, {bad_structure, lists:reverse(Stack)}}).

parse_mbr_partitions([], _I, _Stack, _Opts, Acc) ->
    lists:reverse(Acc);
parse_mbr_partitions([{Role, Props} | Rem], I, Stack, _Opts, Acc)
  when Role =:= system ->
    %TODO: Factorize this duplicated code
    Stack2 = [Role, I | Stack],
    Part = #mbr_partition{
        role = Role,
        id = get_reqint(Props, Stack2, id),
        type = get_reqenum(Props, Stack2, type, [dos]),
        start = get_reqint(Props, Stack2, start),
        size = get_reqint(Props, Stack2, size)
    },
    parse_mbr_partitions(Rem, I + 1, Stack, _Opts, [Part | Acc]);
parse_mbr_partitions([{Role, Props} | Rem], I, Stack, _Opts, Acc)
  when Role =:= data; Role =:= boot ->
    %TODO: Factorize this duplicated code
    Stack2 = [Role, I | Stack],
    Part = #mbr_partition{
        role = Role,
        type = get_reqenum(Props, Stack2, type, [dos]),
        start = get_reqint(Props, Stack2, start),
        size = get_reqint(Props, Stack2, size)
    },
    parse_mbr_partitions(Rem, I + 1, Stack, _Opts, [Part | Acc]);
parse_mbr_partitions([{Role, _} | _], I, Stack, _Opts, _Acc) ->
    throw({bad_manifest, {bad_partition_role, lists:reverse([I | Stack]), Role}});
parse_mbr_partitions(_, I, Stack, _Opts, _Acc) ->
    throw({bad_manifest, {bad_partition, lists:reverse([I | Stack])}}).

parse_gpt_partitions([], _I, _Stack, _Opts, Acc) ->
    lists:reverse(Acc);
parse_gpt_partitions([{Role, Props} | Rem], I, Stack, _Opts, Acc)
  when Role =:= system ->
    %TODO: Factorize this duplicated code
    Stack2 = [Role, I | Stack],
    Part = #gpt_partition{
        role = Role,
        id = get_reqint(Props, Stack2, id),
        type = get_requuid(Props, Stack2, type),
        uuid = get_requuid(Props, Stack2, uuid),
        start = get_reqint(Props, Stack2, start),
        size = get_reqint(Props, Stack2, size)
    },
    parse_gpt_partitions(Rem, I + 1, Stack, _Opts, [Part | Acc]);
parse_gpt_partitions([{Role, Props} | Rem], I, Stack, _Opts, Acc)
  when Role =:= data; Role =:= boot ->
    %TODO: Factorize this duplicated code
    Stack2 = [Role, I | Stack],
    Part = #gpt_partition{
        role = Role,
        type = get_requuid(Props, Stack2, type),
        uuid = get_requuid(Props, Stack2, uuid),
        start = get_reqint(Props, Stack2, start),
        size = get_reqint(Props, Stack2, size)
    },
    parse_gpt_partitions(Rem, I + 1, Stack, _Opts, [Part | Acc]);
parse_gpt_partitions([{Role, _} | _], I, Stack, _Opts, _Acc) ->
    throw({bad_manifest, {bad_partition_role, lists:reverse([I | Stack]), Role}});
parse_gpt_partitions(_, I, Stack, _Opts, _Acc) ->
    throw({bad_manifest, {bad_partition, lists:reverse([I | Stack])}}).

parse_objects([], _I, _Stack, _Opts, Acc, C, D, B) ->
    {lists:reverse(Acc), C, D, B};
parse_objects([{Type, Props} | Rem], I, Stack, Opts, Acc, C, D, B) ->
    Stack2 = [I | Stack],
    case filter_object(Type, Props, Stack2, Opts) of
        false ->
            parse_objects(Rem, I + 1, Stack, Opts, Acc, C, D, B);
        true ->
            TargetProps = get_reqtup(Props, Stack2, target),
            Target = parse_target(TargetProps, [target | Stack2]),
            ContentProps = get_optlist(Props, Stack2, content),
            {Blocks, Co, Do, Bo} =
                parse_content(ContentProps, 0, [content | Stack2], Opts,
                              [], 0, 0, 0),
            Obj = #object{
                type = Type,
                product = get_optbin(Props, Stack2, product),
                version = get_optver(Props, Stack2, version),
                desc = get_optbin(Props, Stack2, description),
                target = Target,
                blocks = Blocks,
                block_count = Co,
                data_size = Do,
                block_size = Bo
            },
            parse_objects(Rem, I + 1, Stack, Opts,
                          [Obj | Acc], C + Co, D + Do, B + Bo)
    end;
parse_objects(_, I, Stack, _Opts, _Acc, _C, _D, _B) ->
    throw({bad_manifest, {bad_object, lists:reverse([I | Stack])}}).

parse_target({raw, Props}, Stack) ->
    #raw_target_spec{
        context = get_reqenum(Props, Stack, context, [global, system]),
        offset = get_reqint(Props, Stack, offset)
    };
parse_target({file, Props}, Stack) ->
    #file_target_spec{
        context = get_reqenum(Props, Stack, context, [global, system]),
        path = get_reqbin(Props, Stack, path)
    };
parse_target({T, _}, Stack) ->
    throw({bad_manifest, {bad_target_type, lists:reverse(Stack), T}});
parse_target(_, Stack) ->
    throw({bad_manifest, {bad_target, lists:reverse(Stack)}}).

parse_content([], _I, _Stack, _Opts, Acc, C, D, B) ->
    {lists:reverse(Acc), C, D, B};
parse_content([{block, Props} | Rem], I, Stack, Opts, Acc, C, D, B) ->
    Stack2 = [block, I | Stack],
    DataHashes = get_reqlist(Props, Stack2, data_hashes),
    DataHashesStack = [data_hashes | Stack2],
    {DataHashType, DataHash} =
        choose_hash(DataHashes, DataHashesStack, [sha256]),
    DataSize = get_reqint(Props, Stack, data_size),
    {BlockEncoding, B2} =
        case get_reqenum(Props, Stack, block_format, [raw, gzip]) of
            raw ->
                {#raw_encoding{
                    block_path = get_reqbin(Props, Stack, block_path)
                 }, DataSize};
            gzip ->
                BlockHashes = get_reqlist(Props, Stack2, block_hashes),
                BlockHashesStack = [block_hashes | Stack2],
                {BlockHashType, BlockHash} =
                    choose_hash(BlockHashes, BlockHashesStack, [sha256]),
                BlockSize = get_reqint(Props, Stack, block_size),
                {#gzip_encoding{
                    block_size = BlockSize,
                    block_crc = get_reqint(BlockHashes, BlockHashesStack, crc32),
                    block_hash_type = BlockHashType,
                    block_hash_data = BlockHash,
                    block_path = get_reqbin(Props, Stack, block_path)
                 }, BlockSize}
        end,
    Block = #block{
        id = I,
        data_offset = get_reqint(Props, Stack, data_offset),
        data_size = DataSize,
        data_crc = get_reqint(DataHashes, DataHashesStack, crc32),
        data_hash_type = DataHashType,
        data_hash_data = DataHash,
        encoding = BlockEncoding
    },
    parse_content(Rem, I + 1, Stack, Opts, [Block | Acc],
                  C + 1, D + DataSize, B + B2);
parse_content([{T, _} | _], I, Stack, _Opts, _Acc, _C, _D, _B) ->
    throw({bad_manifest, {bad_content_type, lists:reverse([I | Stack]), T}});
parse_content(_, I, Stack, _Opts, _Acc, _C, _D, _B) ->
    throw({bad_manifest, {bad_content, lists:reverse([I | Stack])}}).


filter_object(Type, Props, Stack, Opts) ->
    filter_object_action(Type, Props, Stack, Opts)
        andalso filter_object_flags(Type, Props, Stack, Opts).

filter_object_action(_Type, Props, Stack, #{action := Action}) ->
    case get_optlist(Props, Stack, actions) of
        [] -> true;
        Actions -> lists:member(Action, Actions)
    end;
filter_object_action(_type, _Props, _Stack, _Opts) ->
    true.

filter_object_flags(bootloader, _Props, _Stack, #{update_bootloader := true}) ->
    true;
filter_object_flags(bootloader, _Props, _Stack, _Opts) ->
    false;
filter_object_flags(_Type, _Props, _Stack, _Opts) ->
    true.


%--- Manifest manipulation functions

get_reqver(Props, Stack, Key) ->
    Path = lists:reverse([Key | Stack]),
    case proplists:lookup(Key, Props) of
        none ->
            throw({bad_manifest, {missing_key, Path}});
        {_, Ver} when is_binary(Ver) ->
            Ver;
        {_, {A, B, C} = Ver}
          when is_integer(A), A >= 0,
               is_integer(B), B >= 0,
               is_integer(C), C >= 0 ->
            Ver;
        {_, Value} ->
            throw({bad_manifest, {bad_value, Path, Value}})
    end.

get_optver(Props, Stack, Key) ->
    Path = lists:reverse([Key | Stack]),
    case proplists:lookup(Key, Props) of
        none ->
            undefined;
        {_, Ver} when is_binary(Ver) ->
            Ver;
        {_, {A, B, C} = Ver}
          when is_integer(A), A >= 0,
               is_integer(B), B >= 0,
               is_integer(C), C >= 0 ->
            Ver;
        {_, Value} ->
            throw({bad_manifest, {bad_value, Path, Value}})
    end.

get_opttup(Props, Stack, Key) ->
    Path = lists:reverse([Key | Stack]),
    case proplists:lookup(Key, Props) of
        none -> undefined;
        {_, Value} when is_tuple(Value) -> Value;
        {_, Value} -> throw({bad_manifest, {bad_value, Path, Value}})
    end.

get_reqtup(Props, Stack, Key) ->
    Path = lists:reverse([Key | Stack]),
    case proplists:lookup(Key, Props) of
        none -> throw({bad_manifest, {missing_key, Path}});
        {_, Value} when is_tuple(Value) -> Value;
        {_, Value} -> throw({bad_manifest, {bad_value, Path, Value}})
    end.

get_optlist(Props, Stack, Key) ->
    Path = lists:reverse([Key | Stack]),
    case proplists:lookup(Key, Props) of
        none -> [];
        {_, Value} when is_list(Value) -> Value;
        {_, Value} -> throw({bad_manifest, {bad_value, Path, Value}})
    end.

get_reqlist(Props, Stack, Key) ->
    Path = lists:reverse([Key | Stack]),
    case proplists:lookup(Key, Props) of
        none -> throw({bad_manifest, {missing_key, Path}});
        {_, Value} when is_list(Value) -> Value;
        {_, Value} -> throw({bad_manifest, {bad_value, Path, Value}})
    end.

get_optbin(Props, Stack, Key) ->
    Path = lists:reverse([Key | Stack]),
    case proplists:lookup(Key, Props) of
        none -> undefined;
        {_, Value} when is_binary(Value) -> Value;
        {_, Value} -> throw({bad_manifest, {bad_value, Path, Value}})
    end.

get_reqbin(Props, Stack, Key) ->
    Path = lists:reverse([Key | Stack]),
    case proplists:lookup(Key, Props) of
        none -> throw({bad_manifest, {missing_key, Path}});
        {_, Value} when is_binary(Value) -> Value;
        {_, Value} -> throw({bad_manifest, {bad_value, Path, Value}})
    end.

get_reqint(Props, Stack, Key) ->
    Path = lists:reverse([Key | Stack]),
    case proplists:lookup(Key, Props) of
        none -> throw({bad_manifest, {missing_key, Path}});
        {_, Value} when is_integer(Value) -> Value;
        {_, Value} -> throw({bad_manifest, {bad_value, Path, Value}})
    end.

get_reqenum(Props, Stack, Key, Options) ->
    Path = lists:reverse([Key | Stack]),
    case proplists:lookup(Key, Props) of
        none -> throw({bad_manifest, {missing_key, Path}});
        {_, Value} ->
            case lists:member(Value, Options) of
                true -> Value;
                false ->  throw({bad_manifest, {bad_value, Path, Value}})
            end
    end.

get_requuid(Props, Stack, Key) ->
    Path = lists:reverse([Key | Stack]),
    case proplists:lookup(Key, Props) of
        none -> throw({bad_manifest, {missing_key, Path}});
        {_, Value} ->
            try uuid:string_to_uuid(Value) of
                UUID -> UUID
            catch
                exit:badarg ->
                    throw({bad_manifest, {bad_value, Path, Value}})
            end
    end.

choose_hash(_Props, Stack, []) ->
    throw({bad_manifest, {missing_hash, lists:reverse(Stack)}});
choose_hash(Props, Stack, [Key | Rem]) ->
    Path = lists:reverse([Key | Stack]),
    case proplists:lookup(Key, Props) of
        none ->
            choose_hash(Props, Stack, Rem);
        {_, Bin} when is_binary(Bin) ->
            Hash = try
                base64:decode(Bin)
            catch
                _ -> throw({bad_manifest, {bad_value, Path, Bin}})
            end,
            {Key, Hash};
        {_, Value} ->
            throw({bad_manifest, {bad_value, Path, Value}})
    end.
