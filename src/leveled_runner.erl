%% -------- RUNNER ---------
%%
%% A bookie's runner would traditionally allow remote actors to place bets 
%% via the runner.  In this case the runner will allow a remote actor to 
%% have query access to the ledger or journal.  Runners provide a snapshot of
%% the book for querying the backend.  
%%
%% Runners implement the {async, Folder} within Riak backends - returning an 
%% {async, Runner}.  Runner is just a function that provides access to a 
%% snapshot of the database to allow for a particular query.  The
%% Runner may make the snapshot at the point it is called, or the snapshot can
%% be generated and encapsulated within the function (known as snap_prefold).   
%%
%% Runners which view only the Ledger (the Penciller view of the state) may 
%% have a CheckPresence boolean - which causes the function to perform a basic 
%% check that the item is available in the Journal via the Inker as part of 
%% the fold.  This may be useful for anti-entropy folds 


-module(leveled_runner).

-include("include/leveled.hrl").

-export([
            bucket_sizestats/3,
            binary_bucketlist/4,
            index_query/3,
            bucketkey_query/4,
            hashlist_query/3,
            tictactree/5,
            foldheads_allkeys/5,
            foldobjects_allkeys/3,
            foldheads_bybucket/5,
            foldobjects_bybucket/3,
            foldobjects_byindex/3
        ]).


-include_lib("eunit/include/eunit.hrl").

-define(CHECKJOURNAL_PROB, 0.2).

%%%============================================================================
%%% External functions
%%%============================================================================


-spec bucket_sizestats(fun(), any(), atom()) -> {async, fun()}.
%% @doc
%% Fold over a bucket accumulating the count of objects and their total sizes
bucket_sizestats(SnapFun, Bucket, Tag) ->
    StartKey = leveled_codec:to_ledgerkey(Bucket, null, Tag),
    EndKey = leveled_codec:to_ledgerkey(Bucket, null, Tag),
    AccFun = accumulate_size(),
    Runner = 
        fun() ->
            {ok, LedgerSnap, _JournalSnap} = SnapFun(),
            Acc = leveled_penciller:pcl_fetchkeys(LedgerSnap,
                                                    StartKey,
                                                    EndKey,
                                                    AccFun,
                                                    {0, 0}),
            ok = leveled_penciller:pcl_close(LedgerSnap),
            Acc
        end,
    {async, Runner}.

-spec binary_bucketlist(fun(), atom(), fun(), any()) -> {async, fun()}.
%% @doc
%% List buckets for tag, assuming bucket names are all binary type
binary_bucketlist(SnapFun, Tag, FoldBucketsFun, InitAcc) ->
    Runner = 
        fun() ->
            {ok, LedgerSnapshot, _JournalSnapshot} = SnapFun(),
            BucketAcc = get_nextbucket(null, null, Tag, LedgerSnapshot, []),
            ok = leveled_penciller:pcl_close(LedgerSnapshot),
            lists:foldl(fun({B, _K}, Acc) -> FoldBucketsFun(B, Acc) end,
                            InitAcc,
                            BucketAcc)
        end,
    {async, Runner}.

-spec index_query(fun(), tuple(), tuple()) -> {async, fun()}.
%% @doc
%% Secondary index query
index_query(SnapFun, {StartKey, EndKey, TermHandling}, FoldAccT) ->
    {FoldKeysFun, InitAcc} = FoldAccT,
    {ReturnTerms, TermRegex} = TermHandling,
    AddFun = 
        case ReturnTerms of
            true ->
                fun add_terms/2;
            _ ->
                fun add_keys/2
        end,
    AccFun = accumulate_index(TermRegex, AddFun, FoldKeysFun),
    Runner = 
        fun() ->
            {ok, LedgerSnapshot, _JournalSnapshot} = SnapFun(),
            Acc = leveled_penciller:pcl_fetchkeys(LedgerSnapshot,
                                                    StartKey,
                                                    EndKey,
                                                    AccFun,
                                                    InitAcc),
            ok = leveled_penciller:pcl_close(LedgerSnapshot),
            Acc
        end,
    {async, Runner}.

-spec bucketkey_query(fun(), atom(), any(), tuple()) -> {async, fun()}.
%% @doc
%% Fold over all keys under tak (potentially restricted to a given bucket)
bucketkey_query(SnapFun, Tag, Bucket, {FoldKeysFun, InitAcc}) ->
    SK = leveled_codec:to_ledgerkey(Bucket, null, Tag),
    EK = leveled_codec:to_ledgerkey(Bucket, null, Tag),
    AccFun = accumulate_keys(FoldKeysFun),
    Runner = 
        fun() ->
            {ok, LedgerSnapshot, _JournalSnapshot} = SnapFun(),
            Acc = leveled_penciller:pcl_fetchkeys(LedgerSnapshot,
                                                        SK,
                                                        EK,
                                                        AccFun,
                                                        InitAcc),
            ok = leveled_penciller:pcl_close(LedgerSnapshot),
            Acc
        end,
    {async, Runner}.

-spec hashlist_query(fun(), atom(), boolean()) -> {async, fun()}.
%% @doc
%% Fold pver the key accumulating the hashes
hashlist_query(SnapFun, Tag, JournalCheck) ->
    StartKey = leveled_codec:to_ledgerkey(null, null, Tag),
    EndKey = leveled_codec:to_ledgerkey(null, null, Tag),
    Runner = 
        fun() ->
            {ok, LedgerSnapshot, JournalSnapshot} = SnapFun(),
            AccFun = accumulate_hashes(JournalCheck, JournalSnapshot),    
            Acc = leveled_penciller:pcl_fetchkeys(LedgerSnapshot,
                                                        StartKey,
                                                        EndKey,
                                                        AccFun,
                                                        []),
            ok = leveled_penciller:pcl_close(LedgerSnapshot),
            case JournalCheck of
                false ->
                    ok;
                true ->
                    leveled_inker:ink_close(JournalSnapshot)
            end,
            Acc
        end,
    {async, Runner}.

-spec tictactree(fun(), {atom(), any(), tuple()}, boolean(), atom(), fun()) 
                    -> {async, fun()}.
%% @doc
%% Return a merkle tree from the fold, directly accessing hashes cached in the 
%% metadata
tictactree(SnapFun, {Tag, Bucket, Query}, JournalCheck, TreeSize, Filter) ->
    % Journal check can be used for object key folds to confirm that the
    % object is still indexed within the journal
    Tree = leveled_tictac:new_tree(temp, TreeSize),
    Runner =
        fun() ->
            {ok, LedgerSnap, JournalSnap} = SnapFun(),
            % The start key and end key will vary depending on whether the
            % fold is to fold over an index or a key range
            EnsureKeyBinaryFun = 
                fun(K, T) -> 
                    case is_binary(K) of 
                        true ->
                            {K, T};
                        false ->
                            {term_to_binary(K), T}
                    end 
                end,
            {StartKey, EndKey, ExtractFun} =
                case Tag of
                    ?IDX_TAG ->
                        {IdxFld, StartIdx, EndIdx} = Query,
                        KeyDefFun = fun leveled_codec:to_ledgerkey/5,
                        {KeyDefFun(Bucket, null, ?IDX_TAG, IdxFld, StartIdx),
                            KeyDefFun(Bucket, null, ?IDX_TAG, IdxFld, EndIdx),
                            EnsureKeyBinaryFun};
                    _ ->
                        {StartOKey, EndOKey} = Query,
                        {leveled_codec:to_ledgerkey(Bucket, StartOKey, Tag),
                            leveled_codec:to_ledgerkey(Bucket, EndOKey, Tag),
                            fun(K, H) -> 
                                V = {is_hash, H},
                                EnsureKeyBinaryFun(K, V)
                            end}
                end,
            AccFun = 
                accumulate_tree(Filter, JournalCheck, JournalSnap, ExtractFun),
            Acc = 
                leveled_penciller:pcl_fetchkeys(LedgerSnap, 
                                                StartKey, EndKey,
                                                AccFun, Tree),

            % Close down snapshot when complete so as not to hold removed
            % files open
            ok = leveled_penciller:pcl_close(LedgerSnap),
            case JournalCheck of
                false ->
                    ok;
                true ->
                    leveled_inker:ink_close(JournalSnap)
            end,
            Acc
        end,
    {async, Runner}.

-spec foldheads_allkeys(fun(), atom(), fun(), boolean(), false|list(integer())) 
                                                            -> {async, fun()}.
%% @doc
%% Fold over all heads in the store for a given tag - applying the passed 
%% function to each proxy object
foldheads_allkeys(SnapFun, Tag, FoldFun, JournalCheck, SegmentList) ->
    StartKey = leveled_codec:to_ledgerkey(null, null, Tag),
    EndKey = leveled_codec:to_ledgerkey(null, null, Tag),
    foldobjects(SnapFun, 
                Tag, StartKey, EndKey, 
                FoldFun, 
                {true, JournalCheck}, SegmentList).

-spec foldobjects_allkeys(fun(), atom(), fun()) -> {async, fun()}.
%% @doc
%% Fold over all objects for a given tag
foldobjects_allkeys(SnapFun, Tag, FoldFun) ->
    StartKey = leveled_codec:to_ledgerkey(null, null, Tag),
    EndKey = leveled_codec:to_ledgerkey(null, null, Tag),
    foldobjects(SnapFun, 
                Tag, StartKey, EndKey, 
                FoldFun, 
                false, false).

-spec foldobjects_bybucket(fun(), {atom(), any(), any()}, fun()) -> 
                                                                {async, fun()}.
%% @doc
%% Fold over all objects within a given key range in a bucket
foldobjects_bybucket(SnapFun, {Tag, StartKey, EndKey}, FoldFun) ->
    foldobjects(SnapFun, 
                Tag, StartKey, EndKey, 
                FoldFun, 
                false, false).

-spec foldheads_bybucket(fun(), 
                            {atom(), any(), any()}, 
                            fun(), 
                            boolean(), false|list(integer())) 
                                                        -> {async, fun()}.
%% @doc
%% Fold over all object metadata within a given key range in a bucket
foldheads_bybucket(SnapFun, 
                    {Tag, StartKey, EndKey}, 
                    FoldFun, 
                    JournalCheck, SegmentList) ->
    foldobjects(SnapFun, 
                Tag, StartKey, EndKey, 
                FoldFun, 
                {true, JournalCheck}, SegmentList).

-spec foldobjects_byindex(fun(), tuple(), fun()) -> {async, fun()}.
%% @doc
%% Folds over an index, fetching the objects associated with the keys returned 
%% and passing those objects into the fold function
foldobjects_byindex(SnapFun, {Tag, Bucket, Field, FromTerm, ToTerm}, FoldFun) ->
    StartKey =
        leveled_codec:to_ledgerkey(Bucket, null, ?IDX_TAG, Field, FromTerm),
    EndKey =
        leveled_codec:to_ledgerkey(Bucket, null, ?IDX_TAG, Field, ToTerm),
    foldobjects(SnapFun, 
                Tag, StartKey, EndKey, 
                FoldFun, 
                false, false).




%%%============================================================================
%%% Internal functions
%%%============================================================================

get_nextbucket(NextBucket, NextKey, Tag, LedgerSnapshot, BKList) ->
    Now = leveled_codec:integer_now(),
    StartKey = leveled_codec:to_ledgerkey(NextBucket, NextKey, Tag),
    EndKey = leveled_codec:to_ledgerkey(null, null, Tag),
    ExtractFun =
        fun(LK, V, _Acc) ->
            {leveled_codec:from_ledgerkey(LK), V}
        end,
    R = leveled_penciller:pcl_fetchnextkey(LedgerSnapshot,
                                                    StartKey,
                                                    EndKey,
                                                    ExtractFun,
                                                    null),
    case R of
        null ->
            leveled_log:log("B0008",[]),
            BKList;
        {{B, K}, V} when is_binary(B), is_binary(K) ->
            case leveled_codec:is_active({B, K}, V, Now) of
                true ->
                    leveled_log:log("B0009",[B]),
                    get_nextbucket(<<B/binary, 0>>,
                                    null,
                                    Tag,
                                    LedgerSnapshot,
                                    [{B, K}|BKList]);
                false ->
                    get_nextbucket(B,
                                    <<K/binary, 0>>,
                                    Tag,
                                    LedgerSnapshot,
                                    BKList)
            end;
        {NB, _V} ->
            leveled_log:log("B0010",[NB]),
            []
    end.


-spec foldobjects(fun(), atom(), tuple(), tuple(), fun(), 
                    false|{true, boolean()}, false|list(integer())) ->
                                                            {async, fun()}.
%% @doc
%% The object folder should be passed DeferredFetch.
%% DeferredFetch can either be false (which will return to the fold function
%% the full object), or {true, CheckPresence} - in which case a proxy object
%% will be created that if understood by the fold function will allow the fold
%% function to work on the head of the object, and defer fetching the body in
%% case such a fetch is unecessary.
foldobjects(SnapFun, 
            Tag, StartKey, EndKey, 
            FoldObjectsFun, 
            DeferredFetch, SegmentList) ->
    {FoldFun, InitAcc} =
        case is_tuple(FoldObjectsFun) of
            true ->
                % FoldObjectsFun is already a tuple with a Fold function and an
                % initial accumulator
                FoldObjectsFun;
            false ->
                % no initial accumulatr passed, and so should be just a list
                {FoldObjectsFun, []}
        end,
    
    Folder =
        fun() ->
            {ok, LedgerSnapshot, JournalSnapshot} = SnapFun(),

            AccFun = accumulate_objects(FoldFun,
                                        JournalSnapshot,
                                        Tag,
                                        DeferredFetch),
            Acc = leveled_penciller:pcl_fetchkeysbysegment(LedgerSnapshot,
                                                            StartKey,
                                                            EndKey,
                                                            AccFun,
                                                            InitAcc, 
                                                            SegmentList),
            ok = leveled_penciller:pcl_close(LedgerSnapshot),
            case DeferredFetch of 
                {true, false} ->
                    ok;
                _ ->
                    ok = leveled_inker:ink_close(JournalSnapshot)
            end,
            Acc
        end,
    {async, Folder}.


accumulate_size() ->
    Now = leveled_codec:integer_now(),
    AccFun = fun(Key, Value, {Size, Count}) ->
                    case leveled_codec:is_active(Key, Value, Now) of
                            true ->
                                {Size + leveled_codec:get_size(Key, Value),
                                    Count + 1};
                            false ->
                                {Size, Count}
                        end
                end,
    AccFun.

accumulate_hashes(JournalCheck, InkerClone) ->
    AddKeyFun =
        fun(B, K, H, Acc) ->
            [{B, K, H}|Acc]
        end,
    get_hashaccumulator(JournalCheck,
                            InkerClone,
                            AddKeyFun).

accumulate_tree(FilterFun, JournalCheck, InkerClone, HashFun) ->
    AddKeyFun =
        fun(B, K, H, Tree) ->
            case FilterFun(B, K) of
                accumulate ->
                    leveled_tictac:add_kv(Tree, K, H, HashFun);
                pass ->
                    Tree
            end
        end,
    get_hashaccumulator(JournalCheck,
                        InkerClone,
                        AddKeyFun).

get_hashaccumulator(JournalCheck, InkerClone, AddKeyFun) ->
    Now = leveled_codec:integer_now(),
    AccFun =
        fun(LK, V, Acc) ->
            case leveled_codec:is_active(LK, V, Now) of
                true ->
                    {B, K, H} = leveled_codec:get_keyandobjhash(LK, V),
                    Check = leveled_rand:uniform() < ?CHECKJOURNAL_PROB,
                    case {JournalCheck, Check} of
                        {true, true} ->
                            case check_presence(LK, V, InkerClone) of
                                true ->
                                    AddKeyFun(B, K, H, Acc);
                                false ->
                                    Acc
                            end;
                        _ ->
                            AddKeyFun(B, K, H, Acc)
                    end;
                false ->
                    Acc
            end
        end,
    AccFun.


accumulate_objects(FoldObjectsFun, InkerClone, Tag, DeferredFetch) ->
    Now = leveled_codec:integer_now(),
    AccFun =
        fun(LK, V, Acc) ->
            % The function takes the Ledger Key and the value from the
            % ledger (with the value being the object metadata)
            %
            % Need to check if this is an active object (so TTL has not
            % expired).
            % If this is a deferred_fetch (i.e. the fold is a fold_heads not
            % a fold_objects), then a metadata object needs to be built to be
            % returned - but a quick check that Key is present in the Journal
            % is made first
            case leveled_codec:is_active(LK, V, Now) of
                true ->
                    {SQN, _St, _MH, MD} =
                        leveled_codec:striphead_to_details(V),
                    {B, K} =
                        case leveled_codec:from_ledgerkey(LK) of
                            {B0, K0} ->
                                {B0, K0};
                            {B0, K0, _T0} ->
                                {B0, K0}
                        end,
                    JK = {leveled_codec:to_ledgerkey(B, K, Tag), SQN},
                    case DeferredFetch of
                        {true, true} ->
                            InJournal =
                                leveled_inker:ink_keycheck(InkerClone,
                                                            LK,
                                                            SQN),
                            case InJournal of
                                probably ->
                                    ProxyObj = make_proxy_object(LK, JK,
                                                                  MD, V,
                                                                  InkerClone),
                                    FoldObjectsFun(B, K, ProxyObj, Acc);
                                missing ->
                                    Acc
                            end;
                        {true, false} ->
                            ProxyObj = make_proxy_object(LK, JK,
                                                          MD, V,
                                                          InkerClone),
                            FoldObjectsFun(B, K,ProxyObj, Acc);
                        false ->
                            R = leveled_bookie:fetch_value(InkerClone, JK),
                            case R of
                                not_present ->
                                    Acc;
                                Value ->
                                    FoldObjectsFun(B, K, Value, Acc)

                            end
                    end;
                false ->
                    Acc
            end
        end,
    AccFun.

make_proxy_object(LK, JK, MD, V, InkerClone) ->
    Size = leveled_codec:get_size(LK, V),
    MDBin = leveled_codec:build_metadata_object(LK, MD),
    term_to_binary({proxy_object,
                    MDBin,
                    Size,
                    {fun leveled_bookie:fetch_value/2, InkerClone, JK}}).

check_presence(Key, Value, InkerClone) ->
    {LedgerKey, SQN} = leveled_codec:strip_to_keyseqonly({Key, Value}),
    case leveled_inker:ink_keycheck(InkerClone, LedgerKey, SQN) of
        probably ->
            true;
        missing ->
            false
    end.

accumulate_keys(FoldKeysFun) ->
    Now = leveled_codec:integer_now(),
    AccFun = fun(Key, Value, Acc) ->
                    case leveled_codec:is_active(Key, Value, Now) of
                        true ->
                            {B, K} = leveled_codec:from_ledgerkey(Key),
                            FoldKeysFun(B, K, Acc);
                        false ->
                            Acc
                    end
                end,
    AccFun.

add_keys(ObjKey, _IdxValue) ->
    ObjKey.

add_terms(ObjKey, IdxValue) ->
    {IdxValue, ObjKey}.

accumulate_index(TermRe, AddFun, FoldKeysFun) ->
    Now = leveled_codec:integer_now(),
    case TermRe of
        undefined ->
            fun(Key, Value, Acc) ->
                case leveled_codec:is_active(Key, Value, Now) of
                    true ->
                        {Bucket,
                            ObjKey,
                            IdxValue} = leveled_codec:from_ledgerkey(Key),
                        FoldKeysFun(Bucket, AddFun(ObjKey, IdxValue), Acc);
                    false ->
                        Acc
                end end;
        TermRe ->
            fun(Key, Value, Acc) ->
                case leveled_codec:is_active(Key, Value, Now) of
                    true ->
                        {Bucket,
                            ObjKey,
                            IdxValue} = leveled_codec:from_ledgerkey(Key),
                        case re:run(IdxValue, TermRe) of
                            nomatch ->
                                Acc;
                            _ ->
                                FoldKeysFun(Bucket,
                                            AddFun(ObjKey, IdxValue),
                                            Acc)
                        end;
                    false ->
                        Acc
                end end
    end.


%%%============================================================================
%%% Test
%%%============================================================================

-ifdef(TEST).



-endif.

    
    