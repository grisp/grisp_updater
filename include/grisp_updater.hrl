
%--- Records -------------------------------------------------------------------

-record(target, {
    device :: binary(),
    offset :: non_neg_integer(),
    size :: undefined | non_neg_integer()
}).

-type target() :: #target{}.

-record(raw_encoding, {
    block_path :: binary()
}).

-record(gzip_encoding, {
    block_size :: non_neg_integer(),
    block_crc :: integer(),
    block_hash_type :: atom(),
    block_hash_data :: binary(),
    block_path :: binary()
}).

-type block_encoding() :: #raw_encoding{} | #gzip_encoding{}.

-record(block, {
    id :: non_neg_integer(),
    data_offset :: integer(),
    data_size :: non_neg_integer(),
    data_crc :: integer(),
    data_hash_type :: atom(),
    data_hash_data :: binary(),
    encoding :: block_encoding()
}).

-type target_context() :: global | system.

-record(raw_target_spec, {
    context :: target_context(),
    offset :: integer()
}).

-record(file_target_spec, {
    context :: target_context(),
    path :: binary()
}).

-type target_spec() :: #raw_target_spec{} | #file_target_spec{}.

-record(object, {
    type :: bootloader | kernel | rootfs,
    product :: undefined | binary(),
    version :: undefined | binary(),
    desc :: undefined | binary(),
    target :: target_spec(),
    blocks = [] :: [#block{}],
    block_count = 0 :: non_neg_integer(),
    data_size = 0 :: non_neg_integer(),
    block_size = 0 :: non_neg_integer()
}).

-record(mbr_partition, {
    role :: boot | system | data,
    id :: undefined | non_neg_integer(),
    type :: dos,
    start :: non_neg_integer(),
    size :: non_neg_integer()
}).

-record(mbr, {
    sector_size :: non_neg_integer(),
    partitions = [] :: [#mbr_partition{}]
}).

-record(gpt_partition, {
    role :: boot | system | data,
    id :: undefined | non_neg_integer(),
    type :: uuid:uuid(),
    uuid :: uuid:uuid(),
    start :: non_neg_integer(),
    size :: non_neg_integer()
}).

-record(gpt, {
    sector_size :: non_neg_integer(),
    partitions = [] :: [#gpt_partition{}]
}).


-type structure() :: #mbr{} | #gpt{}.

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