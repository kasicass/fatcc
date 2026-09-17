%% .fc container encode/decode.
%%
%% v0 layout:
%%   "FATB" | u16 version | u32 payload_size | u32 crc32 | payload
%% payload is a compressed term_to_binary(#image{}) for now; the chunked
%% container described in doc/design.md will replace it without changing the
%% magic/version/crc envelope.
-module(fat_format).
-include("fat_image.hrl").

-export([encode/1, decode/1]).

-define(VERSION, 16#0001).

-spec encode(#image{}) -> binary().
encode(#image{} = Image) ->
    Payload = term_to_binary(Image, [compressed]),
    Size = byte_size(Payload),
    Crc = erlang:crc32(Payload),
    <<"FATB", ?VERSION:16/little, Size:32/little, Crc:32/little, Payload/binary>>.

-spec decode(binary()) -> {ok, #image{}} | {error, term()}.
decode(<<"FATB", Ver:16/little, Size:32/little, Crc:32/little, Payload/binary>>) ->
    case Ver of
        ?VERSION ->
            case byte_size(Payload) of
                Size ->
                    case erlang:crc32(Payload) of
                        Crc -> decode_payload(Payload);
                        _ -> {error, crc_mismatch}
                    end;
                _ -> {error, {size_mismatch, byte_size(Payload), Size}}
            end;
        _ -> {error, {unsupported_version, Ver}}
    end;
decode(_) ->
    {error, bad_magic}.

decode_payload(Payload) ->
    %% NOTE: [safe] would reject any atom not already interned (e.g. user
    %% struct tags / instruction names in modules not yet loaded). The v0
    %% envelope relies on the CRC + size checks; the chunked decoder described
    %% in doc/design.md will be the real security boundary.
    try binary_to_term(Payload) of
        #image{} = Image -> {ok, Image};
        _ -> {error, not_an_image}
    catch
        error:badarg -> {error, corrupt_payload}
    end.
