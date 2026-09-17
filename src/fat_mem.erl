%% Byte-addressable, little-endian memory.
%%
%% v0 uses a sparse map from address to byte. Reads of never-written bytes
%% return 0 (which models .bss and freshly allocated heap). This is simple and
%% correct; the paged copy-on-write representation from doc/design.md will
%% replace it once profiling demands it.
-module(fat_mem).

-export([new/0, read/4, write/4, read_bytes/3, write_bytes/3,
         read_cstr/2, copy/4, size/1]).

-type mem() :: map().
-export_type([mem/0]).

new() -> #{}.

-spec read(mem(), non_neg_integer(), non_neg_integer(), signed | unsigned) ->
          {integer(), mem()}.
read(Mem, _Addr, 0, _Sign) -> {0, Mem};
read(Mem, Addr, Size, Sign) ->
    Bytes = [maps:get(Addr + I, Mem, 0) || I <- lists:seq(0, Size - 1)],
    V0 = bytes_to_int(Bytes),
    V = case Sign of
            signed -> sign_extend(V0, Size);
            unsigned -> V0
        end,
    {V, Mem}.

-spec write(mem(), non_neg_integer(), non_neg_integer(), integer()) -> mem().
write(Mem, _Addr, 0, _V) -> Mem;
write(Mem, Addr, Size, V) ->
    Bytes = int_to_bytes(V, Size),
    lists:foldl(
      fun({I, B}, M) -> maps:put(Addr + I, B band 16#FF, M) end,
      Mem, lists:zip(lists:seq(0, Size - 1), Bytes)).

-spec read_bytes(mem(), non_neg_integer(), non_neg_integer()) -> binary().
read_bytes(Mem, Addr, N) ->
    list_to_binary([maps:get(Addr + I, Mem, 0) || I <- lists:seq(0, N - 1)]).

-spec write_bytes(mem(), non_neg_integer(), binary()) -> mem().
write_bytes(Mem, Addr, Bin) ->
    write_bytes(Mem, Addr, Bin, 0).

write_bytes(Mem, _Addr, Bin, Off) when Off >= byte_size(Bin) -> Mem;
write_bytes(Mem, Addr, Bin, Off) ->
    B = binary:at(Bin, Off),
    write_bytes(maps:put(Addr + Off, B, Mem), Addr, Bin, Off + 1).

%% Read a NUL-terminated C string.
-spec read_cstr(mem(), non_neg_integer()) -> binary().
read_cstr(Mem, Addr) ->
    read_cstr(Mem, Addr, []).

read_cstr(Mem, Addr, Acc) ->
    case maps:get(Addr, Mem, 0) of
        0 -> list_to_binary(lists:reverse(Acc));
        B -> read_cstr(Mem, Addr + 1, [B | Acc])
    end.

-spec copy(mem(), non_neg_integer(), non_neg_integer(), non_neg_integer()) -> mem().
copy(Mem, Dest, Src, N) ->
    Bin = read_bytes(Mem, Src, N),
    write_bytes(Mem, Dest, Bin).

size(Mem) -> maps:size(Mem).

%%--------------------------------------------------------------------
bytes_to_int(Bytes) ->
    lists:foldl(fun(B, Acc) -> (Acc bsl 8) bor B end, 0, lists:reverse(Bytes)).

int_to_bytes(V0, Size) ->
    V = V0 band ((1 bsl (Size * 8)) - 1),
    [ (V bsr (8 * I)) band 16#FF || I <- lists:seq(0, Size - 1) ].

sign_extend(V, Size) ->
    Bits = Size * 8,
    Half = 1 bsl (Bits - 1),
    case V >= Half of
        true -> V - (1 bsl Bits);
        false -> V
    end.
