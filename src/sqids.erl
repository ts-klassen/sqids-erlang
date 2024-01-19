-module(sqids).

-export([
        new/0
      , new/1
      , default_options/0
      , encode/2
    ]).

-export_type([
        options/0
      , str/0
      , blocklist/0
      , sqids/0
    ]).

% String representations supported in this module is/are:
%   - non multibyte binary format
-type str() :: unicode:latin1_binary().

-type char_() :: <<_:8>>.

-type blocklist() :: sets:set(str()).

-type options() :: #{
        alphabet   => str()
      , min_length => non_neg_integer()
      , blocklist  => blocklist()
    }.

-opaque sqids() :: #{
       '?MODULE'   := ?MODULE
      , alphabet   := str()
      , min_length := non_neg_integer()
      , blocklist  := blocklist()
      , n          := non_neg_integer()
    }.

-spec default_options() -> options().
default_options() ->
    #{  alphabet   =>
            <<"abcdefghijklmnopqrstuvwxyz",
              "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
              "0123456789">>
      , min_length => 0
      , blocklist  => sqids_blocklist:get()
    }.

-spec new() -> sqids().
new() ->
    new(#{}).

-spec new(options()) -> sqids().
new(#{blocklist:=Blocklist}=Opts) when not is_map(Blocklist) ->
    % Erlang sets has version 1 and 2.
    % Type sqids_blocklist:blocklist() is version 2.
    % This converts version 1 to version 2.
    SetVer2 = case sets:is_set(Blocklist) of
        true ->
            sets:from_list(sets:to_list(Blocklist), [{version, 2}]);
        _ ->
            erlang:error(badarg, [Opts])
    end,
    new(Opts#{blocklist:=SetVer2});
new(Options0) when is_map(Options0)->
    Options = maps:merge(default_options(), Options0),
    case Options of
        #{  alphabet := Alphabet
          , min_length := MinLength
          , blocklist := Blocklist
        } when is_binary(Alphabet)
             , is_integer(MinLength)
             , MinLength >= 0 % no upper limit.
        ->
            case {sets:is_set(Blocklist), is_map(Blocklist)} of
                {true, true} -> ok;
                _ ->
                    erlang:error(badarg, [Options0])
            end;
        _ ->
            erlang:error(badarg, [Options0])
    end,
    BinAlphabet = maps:get(alphabet, Options),
    ListAlphabet = unicode:characters_to_list(BinAlphabet),
    case {size(BinAlphabet), length(ListAlphabet)} of
        {Size, Size} when Size < 3 ->
            Reason0 = 'Alphabet length must be at least 3',
            erlang:error(Reason0, [Options0]);
        {Size, Size} ->
            ok;
        _ ->
            Reason0 = 'Alphabet cannot contain multibyte characters',
            erlang:error(Reason0, [Options0])
    end,
    SetAlphabet = sets:from_list(ListAlphabet, [{version, 2}]),
    case {size(BinAlphabet), sets:size(SetAlphabet)} of
        {SetSize, SetSize} ->
            ok;
        _ ->
            Reason1 = 'Alphabet must contain unique characters',
            erlang:error(Reason1, [Options0])
    end,
    AlphabetLowercased = string:casefold(BinAlphabet),
    AlphabetCharSet = str_to_char_set(AlphabetLowercased),
    FilteredBlocklist = maps:fold(fun
        (Word, [], Acc) when size(Word) >= 3->
            WordLowercased = string:casefold(Word),
            WordChars = str_to_char_list(WordLowercased),
            try
                lists:foreach(fun
                    (C) ->
                        case sets:is_element(C, AlphabetCharSet) of
                            true -> ok;
                            false -> throw({?MODULE, break})
                        end
                    end, WordChars)
            of
                ok ->
                    Acc#{WordLowercased => []}
            catch
                throw:{?MODULE, break} ->
                    Acc
            end;
        (_, [], Acc) ->
            Acc;
        (_, _, _) ->
            erlang:error(badarg, [Options0])
        end, #{}, maps:get(blocklist, Options)),
    #{ '?MODULE'   => ?MODULE
      , alphabet   => shuffle(BinAlphabet)
      , min_length => maps:get(min_length, Options)
      , blocklist  => FilteredBlocklist
      , n          => size(BinAlphabet)
    } ;
new(Options0) ->
    erlang:error(badarg, [Options0]).


-spec encode([non_neg_integer()], sqids()) -> str().
encode([], #{'?MODULE':=?MODULE}) ->
    <<>>;
encode(Numbers, Sqids=#{'?MODULE':=?MODULE}) ->
    encode_numbers(Numbers, 0, Sqids);
encode(Arg1, Arg2) ->
    erlang:error(badarg, [Arg1, Arg2]).

-spec encode_numbers(
        [non_neg_integer()], non_neg_integer(), sqids()
    ) -> str().
encode_numbers(Num, Inc, #{n:=N}=Sqids) when Inc > N ->
    Reason = 'Reached max attempts to re-generate the ID',
    erlang:error(Reason, [Num, Inc, Sqids]);
encode_numbers(Numbers, Increment, Sqids) ->
    This = fun(Key) -> maps:get(Key, Sqids) end,
    {_i, Offset0} = lists:foldl(fun(V, {I, A})->
            Next = binary:at(This(alphabet), V rem This(n)) + I + A,
            {I+1, Next}
        end, {0, length(Numbers)}, Numbers),
    Offset1 = Offset0 rem This(n),
    Offset = (Offset1 + Increment) rem This(n),
    <<SliceLeft:Offset/binary, SliceRight/binary>> = This(alphabet),
    Alphabet0 = <<SliceRight/binary, SliceLeft/binary>>,
    Prefix = binary:at(Alphabet0, 0),
    Alphabet1 = list_to_binary(lists:reverse(binary_to_list(Alphabet0))),
    {RevCharList0, Alphabet2} = encode_input_array(
            Numbers, [Prefix], Alphabet1
        ),
    Id = case This(min_length) of
        MinLength when MinLength > length(RevCharList0) ->
            Separator = binary:at(Alphabet2, 0),
            RevCharList1 = [Separator|RevCharList0],
            Id0 = list_to_binary(lists:reverse(RevCharList1)),
            id_padding(Id0, This(min_length), Alphabet2);
        _ ->
            list_to_binary(lists:reverse(RevCharList0))
    end,
    case is_blocked_id(Id) of
        false ->
            Id;
        _ ->
            encode_numbers(Numbers, Increment+1, Sqids)
    end.

-spec encode_input_array(
        [non_neg_integer(), ...], [non_neg_integer(), ...], str()
    ) -> {[char_(), ...], str()}.
encode_input_array([Num], Id0, Alphabet) ->
    <<_:1/binary, AlphabetWithoutSeparator/binary>> = Alphabet,
    Id1 = [to_id(Num, AlphabetWithoutSeparator)|Id0],
    {Id1, Alphabet};
encode_input_array([Num|Numbers], Id0, Alphabet) ->
    <<Separator:1/binary, AlphabetWithoutSeparator/binary>> = Alphabet,
    Id1 = [to_id(Num, AlphabetWithoutSeparator)|Id0],
    Id2 = [Separator|Id1],
    encode_input_array(Numbers, Id2, shuffle(Alphabet)).

id_padding(Id0, MinLength, Alphabet0) when MinLength - size(Id0) > 0 ->
    Alphabet = shuffle(Alphabet0),
    Size = min(MinLength-size(Id0), size(Alphabet)),
    <<Padding:Size/binary, _/binary>> = Alphabet,
    Id = <<Id0/binary, Padding/binary>>,
    id_padding(Id, MinLength, Alphabet);
id_padding(Id, _MinLength, _Alphabet) ->
    Id.

-spec shuffle(str()) -> str().
shuffle(Alphabet) ->
    % TODO
    Alphabet.

-spec to_id(non_neg_integer(), str()) -> char_().
to_id(_Num, Alphabet) ->
    % TODO
    binary:at(Alphabet, 0).

-spec to_number(str(), str()) -> non_neg_integer().
to_number(_, _) ->
    % TODO
    0.

-spec is_blocked_id(str()) -> boolean().
is_blocked_id(_) ->
    % TODO
    false.

-spec str_to_char_set(str()) -> sets:set(char_()).
str_to_char_set(Str) ->
    List = str_to_char_list(Str),
    sets:from_list(List, [{version, 2}]).

-spec str_to_char_list(str()) -> lists:list(char_()).
str_to_char_list(Str) ->
    lists:map(fun(Char) ->
            <<Char/integer>>
        end, binary_to_list(Str)).

