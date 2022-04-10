
%--- Records -------------------------------------------------------------------

-record(target, {
    device :: binary(),
    offset :: non_neg_integer(),
    size :: undefined | non_neg_integer()
}).

-record(block, {
    id :: non_neg_integer(),
    data_offset :: integer(),
    data_size :: non_neg_integer(),
    data_crc :: integer(),
    data_hash_type :: atom(),
    data_hash_data :: binary(),
    block_format :: gzip,
    block_size :: non_neg_integer(),
    block_crc :: integer(),
    block_hash_type :: atom(),
    block_hash_data :: binary(),
    block_path :: binary()
}).

-record(raw, {
    context :: global | system,
    offset :: integer()
}).

-type target_spec() :: #raw{}.

-record(object, {
    type :: bootloader | rootfs,
    product :: undefined | binary(),
    version :: undefined | binary(),
    desc :: undefined | binary(),
    target :: target_spec(),
    blocks = [] :: [#block{}],
    block_count = 0 :: non_neg_integer(),
    data_size = 0 :: non_neg_integer(),
    block_size = 0 :: non_neg_integer()
}).

-record(vfat_partition, {
    id :: undefined | non_neg_integer(),
    role :: system | data,
    type :: dos,
    start :: non_neg_integer(),
    size :: non_neg_integer()
}).

-record(vfat, {
    sector_size :: non_neg_integer(),
    partitions = [] :: [#vfat_partition{}]
}).

-type structure() :: #vfat{}.

-record(manifest, {
    format :: {non_neg_integer(), non_neg_integer(), non_neg_integer()},
    product :: binary(),
    version :: binary(),
    desc :: undefined | binary(),
    architecture :: binary(),
    structure :: undefined | structure(),
    objects :: [#object{}],
    block_count = 0 :: non_neg_integer(),
    data_size = 0 :: non_neg_integer(),
    block_size = 0 :: non_neg_integer()
}).