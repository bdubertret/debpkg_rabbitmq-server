%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2015 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_queue_index).

-export([erase/1, init/3, recover/6,
         terminate/2, delete_and_terminate/1,
         publish/6, deliver/2, ack/2, sync/1, needs_sync/1, flush/1,
         read/3, next_segment_boundary/1, bounds/1, start/1, stop/0]).

-export([add_queue_ttl/0, avoid_zeroes/0, store_msg_size/0, store_msg/0]).

-define(CLEAN_FILENAME, "clean.dot").

%%----------------------------------------------------------------------------

%% The queue index is responsible for recording the order of messages
%% within a queue on disk. As such it contains records of messages
%% being published, delivered and acknowledged. The publish record
%% includes the sequence ID, message ID and a small quantity of
%% metadata about the message; the delivery and acknowledgement
%% records just contain the sequence ID. A publish record may also
%% contain the complete message if provided to publish/5; this allows
%% the message store to be avoided altogether for small messages. In
%% either case the publish record is stored in memory in the same
%% serialised format it will take on disk.
%%
%% Because of the fact that the queue can decide at any point to send
%% a queue entry to disk, you can not rely on publishes appearing in
%% order. The only thing you can rely on is a message being published,
%% then delivered, then ack'd.
%%
%% In order to be able to clean up ack'd messages, we write to segment
%% files. These files have a fixed number of entries: ?SEGMENT_ENTRY_COUNT
%% publishes, delivers and acknowledgements. They are numbered, and so
%% it is known that the 0th segment contains messages 0 ->
%% ?SEGMENT_ENTRY_COUNT - 1, the 1st segment contains messages
%% ?SEGMENT_ENTRY_COUNT -> 2*?SEGMENT_ENTRY_COUNT - 1 and so on. As
%% such, in the segment files, we only refer to message sequence ids
%% by the LSBs as SeqId rem ?SEGMENT_ENTRY_COUNT. This gives them a
%% fixed size.
%%
%% However, transient messages which are not sent to disk at any point
%% will cause gaps to appear in segment files. Therefore, we delete a
%% segment file whenever the number of publishes == number of acks
%% (note that although it is not fully enforced, it is assumed that a
%% message will never be ackd before it is delivered, thus this test
%% also implies == number of delivers). In practise, this does not
%% cause disk churn in the pathological case because of the journal
%% and caching (see below).
%%
%% Because of the fact that publishes, delivers and acks can occur all
%% over, we wish to avoid lots of seeking. Therefore we have a fixed
%% sized journal to which all actions are appended. When the number of
%% entries in this journal reaches max_journal_entries, the journal
%% entries are scattered out to their relevant files, and the journal
%% is truncated to zero size. Note that entries in the journal must
%% carry the full sequence id, thus the format of entries in the
%% journal is different to that in the segments.
%%
%% The journal is also kept fully in memory, pre-segmented: the state
%% contains a mapping from segment numbers to state-per-segment (this
%% state is held for all segments which have been "seen": thus a
%% segment which has been read but has no pending entries in the
%% journal is still held in this mapping. Also note that a dict is
%% used for this mapping, not an array because with an array, you will
%% always have entries from 0). Actions are stored directly in this
%% state. Thus at the point of flushing the journal, firstly no
%% reading from disk is necessary, but secondly if the known number of
%% acks and publishes in a segment are equal, given the known state of
%% the segment file combined with the journal, no writing needs to be
%% done to the segment file either (in fact it is deleted if it exists
%% at all). This is safe given that the set of acks is a subset of the
%% set of publishes. When it is necessary to sync messages, it is
%% sufficient to fsync on the journal: when entries are distributed
%% from the journal to segment files, those segments appended to are
%% fsync'd prior to the journal being truncated.
%%
%% This module is also responsible for scanning the queue index files
%% and seeding the message store on start up.
%%
%% Note that in general, the representation of a message's state as
%% the tuple: {('no_pub'|{IsPersistent, Bin, MsgBin}),
%% ('del'|'no_del'), ('ack'|'no_ack')} is richer than strictly
%% necessary for most operations. However, for startup, and to ensure
%% the safe and correct combination of journal entries with entries
%% read from the segment on disk, this richer representation vastly
%% simplifies and clarifies the code.
%%
%% For notes on Clean Shutdown and startup, see documentation in
%% variable_queue.
%%
%%----------------------------------------------------------------------------

%% ---- Journal details ----

-define(JOURNAL_FILENAME, "journal.jif").

-define(PUB_PERSIST_JPREFIX, 2#00).
-define(PUB_TRANS_JPREFIX,   2#01).
-define(DEL_JPREFIX,         2#10).
-define(ACK_JPREFIX,         2#11).
-define(JPREFIX_BITS, 2).
-define(SEQ_BYTES, 8).
-define(SEQ_BITS, ((?SEQ_BYTES * 8) - ?JPREFIX_BITS)).

%% ---- Segment details ----

-define(SEGMENT_EXTENSION, ".idx").

%% TODO: The segment size would be configurable, but deriving all the
%% other values is quite hairy and quite possibly noticably less
%% efficient, depending on how clever the compiler is when it comes to
%% binary generation/matching with constant vs variable lengths.

-define(REL_SEQ_BITS, 14).
-define(SEGMENT_ENTRY_COUNT, 16384). %% trunc(math:pow(2,?REL_SEQ_BITS))).

%% seq only is binary 01 followed by 14 bits of rel seq id
%% (range: 0 - 16383)
-define(REL_SEQ_ONLY_PREFIX, 01).
-define(REL_SEQ_ONLY_PREFIX_BITS, 2).
-define(REL_SEQ_ONLY_RECORD_BYTES, 2).

%% publish record is binary 1 followed by a bit for is_persistent,
%% then 14 bits of rel seq id, 64 bits for message expiry, 32 bits of
%% size and then 128 bits of md5sum msg id.
-define(PUB_PREFIX, 1).
-define(PUB_PREFIX_BITS, 1).

-define(EXPIRY_BYTES, 8).
-define(EXPIRY_BITS, (?EXPIRY_BYTES * 8)).
-define(NO_EXPIRY, 0).

-define(MSG_ID_BYTES, 16). %% md5sum is 128 bit or 16 bytes
-define(MSG_ID_BITS, (?MSG_ID_BYTES * 8)).

%% This is the size of the message body content, for stats
-define(SIZE_BYTES, 4).
-define(SIZE_BITS, (?SIZE_BYTES * 8)).

%% This is the size of the message record embedded in the queue
%% index. If 0, the message can be found in the message store.
-define(EMBEDDED_SIZE_BYTES, 4).
-define(EMBEDDED_SIZE_BITS, (?EMBEDDED_SIZE_BYTES * 8)).

%% 16 bytes for md5sum + 8 for expiry
-define(PUB_RECORD_BODY_BYTES, (?MSG_ID_BYTES + ?EXPIRY_BYTES + ?SIZE_BYTES)).
%% + 4 for size
-define(PUB_RECORD_SIZE_BYTES, (?PUB_RECORD_BODY_BYTES + ?EMBEDDED_SIZE_BYTES)).

%% + 2 for seq, bits and prefix
-define(PUB_RECORD_PREFIX_BYTES, 2).

%% ---- misc ----

-define(PUB, {_, _, _}). %% {IsPersistent, Bin, MsgBin}

-define(READ_MODE, [binary, raw, read]).
-define(WRITE_MODE, [write | ?READ_MODE]).

%%----------------------------------------------------------------------------

-record(qistate, {dir, segments, journal_handle, dirty_count,
                  max_journal_entries, on_sync, on_sync_msg,
                  unconfirmed, unconfirmed_msg}).

-record(segment, {num, path, journal_entries, unacked}).

-include("rabbit.hrl").

%%----------------------------------------------------------------------------

-rabbit_upgrade({add_queue_ttl,  local, []}).
-rabbit_upgrade({avoid_zeroes,   local, [add_queue_ttl]}).
-rabbit_upgrade({store_msg_size, local, [avoid_zeroes]}).
-rabbit_upgrade({store_msg,      local, [store_msg_size]}).

-ifdef(use_specs).

-type(hdl() :: ('undefined' | any())).
-type(segment() :: ('undefined' |
                    #segment { num             :: non_neg_integer(),
                               path            :: file:filename(),
                               journal_entries :: array:array(),
                               unacked         :: non_neg_integer()
                             })).
-type(seq_id() :: integer()).
-type(seg_dict() :: {dict:dict(), [segment()]}).
-type(on_sync_fun() :: fun ((gb_sets:set()) -> ok)).
-type(qistate() :: #qistate { dir                 :: file:filename(),
                              segments            :: 'undefined' | seg_dict(),
                              journal_handle      :: hdl(),
                              dirty_count         :: integer(),
                              max_journal_entries :: non_neg_integer(),
                              on_sync             :: on_sync_fun(),
                              on_sync_msg         :: on_sync_fun(),
                              unconfirmed         :: gb_sets:set(),
                              unconfirmed_msg     :: gb_sets:set()
                            }).
-type(contains_predicate() :: fun ((rabbit_types:msg_id()) -> boolean())).
-type(walker(A) :: fun ((A) -> 'finished' |
                               {rabbit_types:msg_id(), non_neg_integer(), A})).
-type(shutdown_terms() :: [term()] | 'non_clean_shutdown').

-spec(erase/1 :: (rabbit_amqqueue:name()) -> 'ok').
-spec(init/3 :: (rabbit_amqqueue:name(),
                 on_sync_fun(), on_sync_fun()) -> qistate()).
-spec(recover/6 :: (rabbit_amqqueue:name(), shutdown_terms(), boolean(),
                    contains_predicate(),
                    on_sync_fun(), on_sync_fun()) ->
                        {'undefined' | non_neg_integer(),
                         'undefined' | non_neg_integer(), qistate()}).
-spec(terminate/2 :: ([any()], qistate()) -> qistate()).
-spec(delete_and_terminate/1 :: (qistate()) -> qistate()).
-spec(publish/6 :: (rabbit_types:msg_id(), seq_id(),
                    rabbit_types:message_properties(), boolean(),
                    non_neg_integer(), qistate()) -> qistate()).
-spec(deliver/2 :: ([seq_id()], qistate()) -> qistate()).
-spec(ack/2 :: ([seq_id()], qistate()) -> qistate()).
-spec(sync/1 :: (qistate()) -> qistate()).
-spec(needs_sync/1 :: (qistate()) -> 'confirms' | 'other' | 'false').
-spec(flush/1 :: (qistate()) -> qistate()).
-spec(read/3 :: (seq_id(), seq_id(), qistate()) ->
                     {[{rabbit_types:msg_id(), seq_id(),
                        rabbit_types:message_properties(),
                        boolean(), boolean()}], qistate()}).
-spec(next_segment_boundary/1 :: (seq_id()) -> seq_id()).
-spec(bounds/1 :: (qistate()) ->
                       {non_neg_integer(), non_neg_integer(), qistate()}).
-spec(start/1 :: ([rabbit_amqqueue:name()]) -> {[[any()]], {walker(A), A}}).

-spec(add_queue_ttl/0 :: () -> 'ok').

-endif.


%%----------------------------------------------------------------------------
%% public API
%%----------------------------------------------------------------------------

erase(Name) ->
    #qistate { dir = Dir } = blank_state(Name),
    case rabbit_file:is_dir(Dir) of
        true  -> rabbit_file:recursive_delete([Dir]);
        false -> ok
    end.

init(Name, OnSyncFun, OnSyncMsgFun) ->
    State = #qistate { dir = Dir } = blank_state(Name),
    false = rabbit_file:is_file(Dir), %% is_file == is file or dir
    State#qistate{on_sync     = OnSyncFun,
                  on_sync_msg = OnSyncMsgFun}.

recover(Name, Terms, MsgStoreRecovered, ContainsCheckFun,
        OnSyncFun, OnSyncMsgFun) ->
    State = blank_state(Name),
    State1 = State #qistate{on_sync     = OnSyncFun,
                            on_sync_msg = OnSyncMsgFun},
    CleanShutdown = Terms /= non_clean_shutdown,
    case CleanShutdown andalso MsgStoreRecovered of
        true  -> RecoveredCounts = proplists:get_value(segments, Terms, []),
                 init_clean(RecoveredCounts, State1);
        false -> init_dirty(CleanShutdown, ContainsCheckFun, State1)
    end.

terminate(Terms, State = #qistate { dir = Dir }) ->
    {SegmentCounts, State1} = terminate(State),
    rabbit_recovery_terms:store(filename:basename(Dir),
                                [{segments, SegmentCounts} | Terms]),
    State1.

delete_and_terminate(State) ->
    {_SegmentCounts, State1 = #qistate { dir = Dir }} = terminate(State),
    ok = rabbit_file:recursive_delete([Dir]),
    State1.

publish(MsgOrId, SeqId, MsgProps, IsPersistent, JournalSizeHint,
        State = #qistate{unconfirmed     = UC,
                         unconfirmed_msg = UCM}) ->
    MsgId = case MsgOrId of
                #basic_message{id = Id} -> Id;
                Id when is_binary(Id)   -> Id
            end,
    ?MSG_ID_BYTES = size(MsgId),
    {JournalHdl, State1} =
        get_journal_handle(
          case {MsgProps#message_properties.needs_confirming, MsgOrId} of
              {true,  MsgId} -> UC1  = gb_sets:add_element(MsgId, UC),
                                State#qistate{unconfirmed     = UC1};
              {true,  _}     -> UCM1 = gb_sets:add_element(MsgId, UCM),
                                State#qistate{unconfirmed_msg = UCM1};
              {false, _}     -> State
          end),
    file_handle_cache_stats:update(queue_index_journal_write),
    {Bin, MsgBin} = create_pub_record_body(MsgOrId, MsgProps),
    ok = file_handle_cache:append(
           JournalHdl, [<<(case IsPersistent of
                               true  -> ?PUB_PERSIST_JPREFIX;
                               false -> ?PUB_TRANS_JPREFIX
                           end):?JPREFIX_BITS,
                          SeqId:?SEQ_BITS, Bin/binary,
                          (size(MsgBin)):?EMBEDDED_SIZE_BITS>>, MsgBin]),
    maybe_flush_journal(
      JournalSizeHint,
      add_to_journal(SeqId, {IsPersistent, Bin, MsgBin}, State1)).

deliver(SeqIds, State) ->
    deliver_or_ack(del, SeqIds, State).

ack(SeqIds, State) ->
    deliver_or_ack(ack, SeqIds, State).

%% This is called when there are outstanding confirms or when the
%% queue is idle and the journal needs syncing (see needs_sync/1).
sync(State = #qistate { journal_handle = undefined }) ->
    State;
sync(State = #qistate { journal_handle = JournalHdl }) ->
    ok = file_handle_cache:sync(JournalHdl),
    notify_sync(State).

needs_sync(#qistate{journal_handle = undefined}) ->
    false;
needs_sync(#qistate{journal_handle  = JournalHdl,
                    unconfirmed     = UC,
                    unconfirmed_msg = UCM}) ->
    case gb_sets:is_empty(UC) andalso gb_sets:is_empty(UCM) of
        true  -> case file_handle_cache:needs_sync(JournalHdl) of
                     true  -> other;
                     false -> false
                 end;
        false -> confirms
    end.

flush(State = #qistate { dirty_count = 0 }) -> State;
flush(State)                                -> flush_journal(State).

read(StartEnd, StartEnd, State) ->
    {[], State};
read(Start, End, State = #qistate { segments = Segments,
                                    dir = Dir }) when Start =< End ->
    %% Start is inclusive, End is exclusive.
    LowerB = {StartSeg, _StartRelSeq} = seq_id_to_seg_and_rel_seq_id(Start),
    UpperB = {EndSeg,   _EndRelSeq}   = seq_id_to_seg_and_rel_seq_id(End - 1),
    {Messages, Segments1} =
        lists:foldr(fun (Seg, Acc) ->
                            read_bounded_segment(Seg, LowerB, UpperB, Acc, Dir)
                    end, {[], Segments}, lists:seq(StartSeg, EndSeg)),
    {Messages, State #qistate { segments = Segments1 }}.

next_segment_boundary(SeqId) ->
    {Seg, _RelSeq} = seq_id_to_seg_and_rel_seq_id(SeqId),
    reconstruct_seq_id(Seg + 1, 0).

bounds(State = #qistate { segments = Segments }) ->
    %% This is not particularly efficient, but only gets invoked on
    %% queue initialisation.
    SegNums = lists:sort(segment_nums(Segments)),
    %% Don't bother trying to figure out the lowest seq_id, merely the
    %% seq_id of the start of the lowest segment. That seq_id may not
    %% actually exist, but that's fine. The important thing is that
    %% the segment exists and the seq_id reported is on a segment
    %% boundary.
    %%
    %% We also don't really care about the max seq_id. Just start the
    %% next segment: it makes life much easier.
    %%
    %% SegNums is sorted, ascending.
    {LowSeqId, NextSeqId} =
        case SegNums of
            []         -> {0, 0};
            [MinSeg|_] -> {reconstruct_seq_id(MinSeg, 0),
                           reconstruct_seq_id(1 + lists:last(SegNums), 0)}
        end,
    {LowSeqId, NextSeqId, State}.

start(DurableQueueNames) ->
    ok = rabbit_recovery_terms:start(),
    {DurableTerms, DurableDirectories} =
        lists:foldl(
          fun(QName, {RecoveryTerms, ValidDirectories}) ->
                  DirName = queue_name_to_dir_name(QName),
                  RecoveryInfo = case rabbit_recovery_terms:read(DirName) of
                                     {error, _}  -> non_clean_shutdown;
                                     {ok, Terms} -> Terms
                                 end,
                  {[RecoveryInfo | RecoveryTerms],
                   sets:add_element(DirName, ValidDirectories)}
          end, {[], sets:new()}, DurableQueueNames),

    %% Any queue directory we've not been asked to recover is considered garbage
    QueuesDir = queues_dir(),
    rabbit_file:recursive_delete(
      [filename:join(QueuesDir, DirName) ||
          DirName <- all_queue_directory_names(QueuesDir),
          not sets:is_element(DirName, DurableDirectories)]),

    rabbit_recovery_terms:clear(),

    %% The backing queue interface requires that the queue recovery terms
    %% which come back from start/1 are in the same order as DurableQueueNames
    OrderedTerms = lists:reverse(DurableTerms),
    {OrderedTerms, {fun queue_index_walker/1, {start, DurableQueueNames}}}.

stop() -> rabbit_recovery_terms:stop().

all_queue_directory_names(Dir) ->
    case rabbit_file:list_dir(Dir) of
        {ok, Entries}   -> [E || E <- Entries,
                                 rabbit_file:is_dir(filename:join(Dir, E))];
        {error, enoent} -> []
    end.

%%----------------------------------------------------------------------------
%% startup and shutdown
%%----------------------------------------------------------------------------

blank_state(QueueName) ->
    blank_state_dir(
      filename:join(queues_dir(), queue_name_to_dir_name(QueueName))).

blank_state_dir(Dir) ->
    {ok, MaxJournal} =
        application:get_env(rabbit, queue_index_max_journal_entries),
    #qistate { dir                 = Dir,
               segments            = segments_new(),
               journal_handle      = undefined,
               dirty_count         = 0,
               max_journal_entries = MaxJournal,
               on_sync             = fun (_) -> ok end,
               on_sync_msg         = fun (_) -> ok end,
               unconfirmed         = gb_sets:new(),
               unconfirmed_msg     = gb_sets:new() }.

init_clean(RecoveredCounts, State) ->
    %% Load the journal. Since this is a clean recovery this (almost)
    %% gets us back to where we were on shutdown.
    State1 = #qistate { dir = Dir, segments = Segments } = load_journal(State),
    %% The journal loading only creates records for segments touched
    %% by the journal, and the counts are based on the journal entries
    %% only. We need *complete* counts for *all* segments. By an
    %% amazing coincidence we stored that information on shutdown.
    Segments1 =
        lists:foldl(
          fun ({Seg, UnackedCount}, SegmentsN) ->
                  Segment = segment_find_or_new(Seg, Dir, SegmentsN),
                  segment_store(Segment #segment { unacked = UnackedCount },
                                SegmentsN)
          end, Segments, RecoveredCounts),
    %% the counts above include transient messages, which would be the
    %% wrong thing to return
    {undefined, undefined, State1 # qistate { segments = Segments1 }}.

init_dirty(CleanShutdown, ContainsCheckFun, State) ->
    %% Recover the journal completely. This will also load segments
    %% which have entries in the journal and remove duplicates. The
    %% counts will correctly reflect the combination of the segment
    %% and the journal.
    State1 = #qistate { dir = Dir, segments = Segments } =
        recover_journal(State),
    {Segments1, Count, Bytes, DirtyCount} =
        %% Load each segment in turn and filter out messages that are
        %% not in the msg_store, by adding acks to the journal. These
        %% acks only go to the RAM journal as it doesn't matter if we
        %% lose them. Also mark delivered if not clean shutdown. Also
        %% find the number of unacked messages. Also accumulate the
        %% dirty count here, so we can call maybe_flush_journal below
        %% and avoid unnecessary file system operations.
        lists:foldl(
          fun (Seg, {Segments2, CountAcc, BytesAcc, DirtyCount}) ->
                  {{Segment = #segment { unacked = UnackedCount }, Dirty},
                   UnackedBytes} =
                      recover_segment(ContainsCheckFun, CleanShutdown,
                                      segment_find_or_new(Seg, Dir, Segments2)),
                  {segment_store(Segment, Segments2),
                   CountAcc + UnackedCount,
                   BytesAcc + UnackedBytes, DirtyCount + Dirty}
          end, {Segments, 0, 0, 0}, all_segment_nums(State1)),
    State2 = maybe_flush_journal(State1 #qistate { segments = Segments1,
                                                   dirty_count = DirtyCount }),
    {Count, Bytes, State2}.

terminate(State = #qistate { journal_handle = JournalHdl,
                             segments = Segments }) ->
    ok = case JournalHdl of
             undefined -> ok;
             _         -> file_handle_cache:close(JournalHdl)
         end,
    SegmentCounts =
        segment_fold(
          fun (#segment { num = Seg, unacked = UnackedCount }, Acc) ->
                  [{Seg, UnackedCount} | Acc]
          end, [], Segments),
    {SegmentCounts, State #qistate { journal_handle = undefined,
                                     segments = undefined }}.

recover_segment(ContainsCheckFun, CleanShutdown,
                Segment = #segment { journal_entries = JEntries }) ->
    {SegEntries, UnackedCount} = load_segment(false, Segment),
    {SegEntries1, UnackedCountDelta} =
        segment_plus_journal(SegEntries, JEntries),
    array:sparse_foldl(
      fun (RelSeq, {{IsPersistent, Bin, MsgBin}, Del, no_ack},
           {SegmentAndDirtyCount, Bytes}) ->
              {MsgOrId, MsgProps} = parse_pub_record_body(Bin, MsgBin),
              {recover_message(ContainsCheckFun(MsgOrId), CleanShutdown,
                               Del, RelSeq, SegmentAndDirtyCount),
               Bytes + case IsPersistent of
                           true  -> MsgProps#message_properties.size;
                           false -> 0
                       end}
      end,
      {{Segment #segment { unacked = UnackedCount + UnackedCountDelta }, 0}, 0},
      SegEntries1).

recover_message( true,  true,   _Del, _RelSeq, SegmentAndDirtyCount) ->
    SegmentAndDirtyCount;
recover_message( true, false,    del, _RelSeq, SegmentAndDirtyCount) ->
    SegmentAndDirtyCount;
recover_message( true, false, no_del,  RelSeq, {Segment, DirtyCount}) ->
    {add_to_journal(RelSeq, del, Segment), DirtyCount + 1};
recover_message(false,     _,    del,  RelSeq, {Segment, DirtyCount}) ->
    {add_to_journal(RelSeq, ack, Segment), DirtyCount + 1};
recover_message(false,     _, no_del,  RelSeq, {Segment, DirtyCount}) ->
    {add_to_journal(RelSeq, ack,
                    add_to_journal(RelSeq, del, Segment)),
     DirtyCount + 2}.

queue_name_to_dir_name(Name = #resource { kind = queue }) ->
    <<Num:128>> = erlang:md5(term_to_binary(Name)),
    rabbit_misc:format("~.36B", [Num]).

queues_dir() ->
    filename:join(rabbit_mnesia:dir(), "queues").

%%----------------------------------------------------------------------------
%% msg store startup delta function
%%----------------------------------------------------------------------------

queue_index_walker({start, DurableQueues}) when is_list(DurableQueues) ->
    {ok, Gatherer} = gatherer:start_link(),
    [begin
         ok = gatherer:fork(Gatherer),
         ok = worker_pool:submit_async(
                fun () -> link(Gatherer),
                          ok = queue_index_walker_reader(QueueName, Gatherer),
                          unlink(Gatherer),
                          ok
                end)
     end || QueueName <- DurableQueues],
    queue_index_walker({next, Gatherer});

queue_index_walker({next, Gatherer}) when is_pid(Gatherer) ->
    case gatherer:out(Gatherer) of
        empty ->
            unlink(Gatherer),
            ok = gatherer:stop(Gatherer),
            finished;
        {value, {MsgId, Count}} ->
            {MsgId, Count, {next, Gatherer}}
    end.

queue_index_walker_reader(QueueName, Gatherer) ->
    State = blank_state(QueueName),
    ok = scan_segments(
           fun (_SeqId, MsgId, _MsgProps, true, _IsDelivered, no_ack, ok)
                 when is_binary(MsgId) ->
                   gatherer:sync_in(Gatherer, {MsgId, 1});
               (_SeqId, _MsgId, _MsgProps, _IsPersistent, _IsDelivered,
                _IsAcked, Acc) ->
                   Acc
           end, ok, State),
    ok = gatherer:finish(Gatherer).

scan_segments(Fun, Acc, State) ->
    State1 = #qistate { segments = Segments, dir = Dir } =
        recover_journal(State),
    Result = lists:foldr(
      fun (Seg, AccN) ->
              segment_entries_foldr(
                fun (RelSeq, {{MsgOrId, MsgProps, IsPersistent},
                              IsDelivered, IsAcked}, AccM) ->
                        Fun(reconstruct_seq_id(Seg, RelSeq), MsgOrId, MsgProps,
                            IsPersistent, IsDelivered, IsAcked, AccM)
                end, AccN, segment_find_or_new(Seg, Dir, Segments))
      end, Acc, all_segment_nums(State1)),
    {_SegmentCounts, _State} = terminate(State1),
    Result.

%%----------------------------------------------------------------------------
%% expiry/binary manipulation
%%----------------------------------------------------------------------------

create_pub_record_body(MsgOrId, #message_properties { expiry = Expiry,
                                                      size   = Size }) ->
    ExpiryBin = expiry_to_binary(Expiry),
    case MsgOrId of
        MsgId when is_binary(MsgId) ->
            {<<MsgId/binary, ExpiryBin/binary, Size:?SIZE_BITS>>, <<>>};
        #basic_message{id = MsgId} ->
            MsgBin = term_to_binary(MsgOrId),
            {<<MsgId/binary, ExpiryBin/binary, Size:?SIZE_BITS>>, MsgBin}
    end.

expiry_to_binary(undefined) -> <<?NO_EXPIRY:?EXPIRY_BITS>>;
expiry_to_binary(Expiry)    -> <<Expiry:?EXPIRY_BITS>>.

parse_pub_record_body(<<MsgIdNum:?MSG_ID_BITS, Expiry:?EXPIRY_BITS,
                        Size:?SIZE_BITS>>, MsgBin) ->
    %% work around for binary data fragmentation. See
    %% rabbit_msg_file:read_next/2
    <<MsgId:?MSG_ID_BYTES/binary>> = <<MsgIdNum:?MSG_ID_BITS>>,
    Props = #message_properties{expiry = case Expiry of
                                             ?NO_EXPIRY -> undefined;
                                             X          -> X
                                         end,
                                size   = Size},
    case MsgBin of
        <<>> -> {MsgId, Props};
        _    -> Msg = #basic_message{id = MsgId} = binary_to_term(MsgBin),
                {Msg, Props}
    end.

%%----------------------------------------------------------------------------
%% journal manipulation
%%----------------------------------------------------------------------------

add_to_journal(SeqId, Action, State = #qistate { dirty_count = DCount,
                                                 segments = Segments,
                                                 dir = Dir }) ->
    {Seg, RelSeq} = seq_id_to_seg_and_rel_seq_id(SeqId),
    Segment = segment_find_or_new(Seg, Dir, Segments),
    Segment1 = add_to_journal(RelSeq, Action, Segment),
    State #qistate { dirty_count = DCount + 1,
                     segments = segment_store(Segment1, Segments) };

add_to_journal(RelSeq, Action,
               Segment = #segment { journal_entries = JEntries,
                                    unacked = UnackedCount }) ->
    Segment #segment {
      journal_entries = add_to_journal(RelSeq, Action, JEntries),
      unacked = UnackedCount + case Action of
                                   ?PUB -> +1;
                                   del  ->  0;
                                   ack  -> -1
                               end};

add_to_journal(RelSeq, Action, JEntries) ->
    case array:get(RelSeq, JEntries) of
        undefined ->
            array:set(RelSeq,
                      case Action of
                          ?PUB -> {Action, no_del, no_ack};
                          del  -> {no_pub,    del, no_ack};
                          ack  -> {no_pub, no_del,    ack}
                      end, JEntries);
        ({Pub,    no_del, no_ack}) when Action == del ->
            array:set(RelSeq, {Pub,    del, no_ack}, JEntries);
        ({no_pub,    del, no_ack}) when Action == ack ->
            array:set(RelSeq, {no_pub, del,    ack}, JEntries);
        ({?PUB,      del, no_ack}) when Action == ack ->
            array:reset(RelSeq, JEntries)
    end.

maybe_flush_journal(State) ->
    maybe_flush_journal(infinity, State).

maybe_flush_journal(Hint, State = #qistate { dirty_count = DCount,
                                             max_journal_entries = MaxJournal })
  when DCount > MaxJournal orelse (Hint =/= infinity andalso DCount > Hint) ->
    flush_journal(State);
maybe_flush_journal(_Hint, State) ->
    State.

flush_journal(State = #qistate { segments = Segments }) ->
    Segments1 =
        segment_fold(
          fun (#segment { unacked = 0, path = Path }, SegmentsN) ->
                  case rabbit_file:is_file(Path) of
                      true  -> ok = rabbit_file:delete(Path);
                      false -> ok
                  end,
                  SegmentsN;
              (#segment {} = Segment, SegmentsN) ->
                  segment_store(append_journal_to_segment(Segment), SegmentsN)
          end, segments_new(), Segments),
    {JournalHdl, State1} =
        get_journal_handle(State #qistate { segments = Segments1 }),
    ok = file_handle_cache:clear(JournalHdl),
    notify_sync(State1 #qistate { dirty_count = 0 }).

append_journal_to_segment(#segment { journal_entries = JEntries,
                                     path = Path } = Segment) ->
    case array:sparse_size(JEntries) of
        0 -> Segment;
        _ -> Seg = array:sparse_foldr(
                     fun entry_to_segment/3, [], JEntries),
             file_handle_cache_stats:update(queue_index_write),

             {ok, Hdl} = file_handle_cache:open(Path, ?WRITE_MODE,
                                                [{write_buffer, infinity}]),
             file_handle_cache:append(Hdl, Seg),
             ok = file_handle_cache:close(Hdl),
             Segment #segment { journal_entries = array_new() }
    end.

get_journal_handle(State = #qistate { journal_handle = undefined,
                                      dir = Dir }) ->
    Path = filename:join(Dir, ?JOURNAL_FILENAME),
    ok = rabbit_file:ensure_dir(Path),
    {ok, Hdl} = file_handle_cache:open(Path, ?WRITE_MODE,
                                       [{write_buffer, infinity}]),
    {Hdl, State #qistate { journal_handle = Hdl }};
get_journal_handle(State = #qistate { journal_handle = Hdl }) ->
    {Hdl, State}.

%% Loading Journal. This isn't idempotent and will mess up the counts
%% if you call it more than once on the same state. Assumes the counts
%% are 0 to start with.
load_journal(State = #qistate { dir = Dir }) ->
    Path = filename:join(Dir, ?JOURNAL_FILENAME),
    case rabbit_file:is_file(Path) of
        true  -> {JournalHdl, State1} = get_journal_handle(State),
                 Size = rabbit_file:file_size(Path),
                 {ok, 0} = file_handle_cache:position(JournalHdl, 0),
                 {ok, JournalBin} = file_handle_cache:read(JournalHdl, Size),
                 parse_journal_entries(JournalBin, State1);
        false -> State
    end.

%% ditto
recover_journal(State) ->
    State1 = #qistate { segments = Segments } = load_journal(State),
    Segments1 =
        segment_map(
          fun (Segment = #segment { journal_entries = JEntries,
                                    unacked = UnackedCountInJournal }) ->
                  %% We want to keep ack'd entries in so that we can
                  %% remove them if duplicates are in the journal. The
                  %% counts here are purely from the segment itself.
                  {SegEntries, UnackedCountInSeg} = load_segment(true, Segment),
                  {JEntries1, UnackedCountDuplicates} =
                      journal_minus_segment(JEntries, SegEntries),
                  Segment #segment { journal_entries = JEntries1,
                                     unacked = (UnackedCountInJournal +
                                                    UnackedCountInSeg -
                                                    UnackedCountDuplicates) }
          end, Segments),
    State1 #qistate { segments = Segments1 }.

parse_journal_entries(<<?DEL_JPREFIX:?JPREFIX_BITS, SeqId:?SEQ_BITS,
                        Rest/binary>>, State) ->
    parse_journal_entries(Rest, add_to_journal(SeqId, del, State));

parse_journal_entries(<<?ACK_JPREFIX:?JPREFIX_BITS, SeqId:?SEQ_BITS,
                        Rest/binary>>, State) ->
    parse_journal_entries(Rest, add_to_journal(SeqId, ack, State));
parse_journal_entries(<<0:?JPREFIX_BITS, 0:?SEQ_BITS,
                        0:?PUB_RECORD_SIZE_BYTES/unit:8, _/binary>>, State) ->
    %% Journal entry composed only of zeroes was probably
    %% produced during a dirty shutdown so stop reading
    State;
parse_journal_entries(<<Prefix:?JPREFIX_BITS, SeqId:?SEQ_BITS,
                        Bin:?PUB_RECORD_BODY_BYTES/binary,
                        MsgSize:?EMBEDDED_SIZE_BITS, MsgBin:MsgSize/binary,
                        Rest/binary>>, State) ->
    IsPersistent = case Prefix of
                       ?PUB_PERSIST_JPREFIX -> true;
                       ?PUB_TRANS_JPREFIX   -> false
                   end,
    parse_journal_entries(
      Rest, add_to_journal(SeqId, {IsPersistent, Bin, MsgBin}, State));
parse_journal_entries(_ErrOrEoF, State) ->
    State.

deliver_or_ack(_Kind, [], State) ->
    State;
deliver_or_ack(Kind, SeqIds, State) ->
    JPrefix = case Kind of ack -> ?ACK_JPREFIX; del -> ?DEL_JPREFIX end,
    {JournalHdl, State1} = get_journal_handle(State),
    file_handle_cache_stats:update(queue_index_journal_write),
    ok = file_handle_cache:append(
           JournalHdl,
           [<<JPrefix:?JPREFIX_BITS, SeqId:?SEQ_BITS>> || SeqId <- SeqIds]),
    maybe_flush_journal(lists:foldl(fun (SeqId, StateN) ->
                                            add_to_journal(SeqId, Kind, StateN)
                                    end, State1, SeqIds)).

notify_sync(State = #qistate{unconfirmed     = UC,
                             unconfirmed_msg = UCM,
                             on_sync         = OnSyncFun,
                             on_sync_msg     = OnSyncMsgFun}) ->
    State1 = case gb_sets:is_empty(UC) of
                 true  -> State;
                 false -> OnSyncFun(UC),
                          State#qistate{unconfirmed = gb_sets:new()}
             end,
    case gb_sets:is_empty(UCM) of
        true  -> State1;
        false -> OnSyncMsgFun(UCM),
                 State1#qistate{unconfirmed_msg = gb_sets:new()}
    end.

%%----------------------------------------------------------------------------
%% segment manipulation
%%----------------------------------------------------------------------------

seq_id_to_seg_and_rel_seq_id(SeqId) ->
    { SeqId div ?SEGMENT_ENTRY_COUNT, SeqId rem ?SEGMENT_ENTRY_COUNT }.

reconstruct_seq_id(Seg, RelSeq) ->
    (Seg * ?SEGMENT_ENTRY_COUNT) + RelSeq.

all_segment_nums(#qistate { dir = Dir, segments = Segments }) ->
    lists:sort(
      sets:to_list(
        lists:foldl(
          fun (SegName, Set) ->
                  sets:add_element(
                    list_to_integer(
                      lists:takewhile(fun (C) -> $0 =< C andalso C =< $9 end,
                                      SegName)), Set)
          end, sets:from_list(segment_nums(Segments)),
          rabbit_file:wildcard(".*\\" ++ ?SEGMENT_EXTENSION, Dir)))).

segment_find_or_new(Seg, Dir, Segments) ->
    case segment_find(Seg, Segments) of
        {ok, Segment} -> Segment;
        error         -> SegName = integer_to_list(Seg)  ++ ?SEGMENT_EXTENSION,
                         Path = filename:join(Dir, SegName),
                         #segment { num             = Seg,
                                    path            = Path,
                                    journal_entries = array_new(),
                                    unacked         = 0 }
    end.

segment_find(Seg, {_Segments, [Segment = #segment { num = Seg } |_]}) ->
    {ok, Segment}; %% 1 or (2, matches head)
segment_find(Seg, {_Segments, [_, Segment = #segment { num = Seg }]}) ->
    {ok, Segment}; %% 2, matches tail
segment_find(Seg, {Segments, _}) -> %% no match
    dict:find(Seg, Segments).

segment_store(Segment = #segment { num = Seg }, %% 1 or (2, matches head)
              {Segments, [#segment { num = Seg } | Tail]}) ->
    {Segments, [Segment | Tail]};
segment_store(Segment = #segment { num = Seg }, %% 2, matches tail
              {Segments, [SegmentA, #segment { num = Seg }]}) ->
    {Segments, [Segment, SegmentA]};
segment_store(Segment = #segment { num = Seg }, {Segments, []}) ->
    {dict:erase(Seg, Segments), [Segment]};
segment_store(Segment = #segment { num = Seg }, {Segments, [SegmentA]}) ->
    {dict:erase(Seg, Segments), [Segment, SegmentA]};
segment_store(Segment = #segment { num = Seg },
              {Segments, [SegmentA, SegmentB]}) ->
    {dict:store(SegmentB#segment.num, SegmentB, dict:erase(Seg, Segments)),
     [Segment, SegmentA]}.

segment_fold(Fun, Acc, {Segments, CachedSegments}) ->
    dict:fold(fun (_Seg, Segment, Acc1) -> Fun(Segment, Acc1) end,
              lists:foldl(Fun, Acc, CachedSegments), Segments).

segment_map(Fun, {Segments, CachedSegments}) ->
    {dict:map(fun (_Seg, Segment) -> Fun(Segment) end, Segments),
     lists:map(Fun, CachedSegments)}.

segment_nums({Segments, CachedSegments}) ->
    lists:map(fun (#segment { num = Num }) -> Num end, CachedSegments) ++
        dict:fetch_keys(Segments).

segments_new() ->
    {dict:new(), []}.

entry_to_segment(_RelSeq, {?PUB, del, ack}, Buf) ->
    Buf;
entry_to_segment(RelSeq, {Pub, Del, Ack}, Buf) ->
    %% NB: we are assembling the segment in reverse order here, so
    %% del/ack comes first.
    Buf1 = case {Del, Ack} of
               {no_del, no_ack} ->
                   Buf;
               _ ->
                   Binary = <<?REL_SEQ_ONLY_PREFIX:?REL_SEQ_ONLY_PREFIX_BITS,
                              RelSeq:?REL_SEQ_BITS>>,
                   case {Del, Ack} of
                       {del, ack} -> [[Binary, Binary] | Buf];
                       _          -> [Binary | Buf]
                   end
           end,
    case Pub of
        no_pub ->
            Buf1;
        {IsPersistent, Bin, MsgBin} ->
            [[<<?PUB_PREFIX:?PUB_PREFIX_BITS,
                (bool_to_int(IsPersistent)):1,
                RelSeq:?REL_SEQ_BITS, Bin/binary,
                (size(MsgBin)):?EMBEDDED_SIZE_BITS>>, MsgBin] | Buf1]
    end.

read_bounded_segment(Seg, {StartSeg, StartRelSeq}, {EndSeg, EndRelSeq},
                     {Messages, Segments}, Dir) ->
    Segment = segment_find_or_new(Seg, Dir, Segments),
    {segment_entries_foldr(
       fun (RelSeq, {{MsgOrId, MsgProps, IsPersistent}, IsDelivered, no_ack},
            Acc)
             when (Seg > StartSeg orelse StartRelSeq =< RelSeq) andalso
                  (Seg < EndSeg   orelse EndRelSeq   >= RelSeq) ->
               [{MsgOrId, reconstruct_seq_id(StartSeg, RelSeq), MsgProps,
                 IsPersistent, IsDelivered == del} | Acc];
           (_RelSeq, _Value, Acc) ->
               Acc
       end, Messages, Segment),
     segment_store(Segment, Segments)}.

segment_entries_foldr(Fun, Init,
                      Segment = #segment { journal_entries = JEntries }) ->
    {SegEntries, _UnackedCount} = load_segment(false, Segment),
    {SegEntries1, _UnackedCountD} = segment_plus_journal(SegEntries, JEntries),
    array:sparse_foldr(
      fun (RelSeq, {{IsPersistent, Bin, MsgBin}, Del, Ack}, Acc) ->
              {MsgOrId, MsgProps} = parse_pub_record_body(Bin, MsgBin),
              Fun(RelSeq, {{MsgOrId, MsgProps, IsPersistent}, Del, Ack}, Acc)
      end, Init, SegEntries1).

%% Loading segments
%%
%% Does not do any combining with the journal at all.
load_segment(KeepAcked, #segment { path = Path }) ->
    Empty = {array_new(), 0},
    case rabbit_file:is_file(Path) of
        false -> Empty;
        true  -> Size = rabbit_file:file_size(Path),
                 file_handle_cache_stats:update(queue_index_read),
                 {ok, Hdl} = file_handle_cache:open(Path, ?READ_MODE, []),
                 {ok, 0} = file_handle_cache:position(Hdl, bof),
                 {ok, SegBin} = file_handle_cache:read(Hdl, Size),
                 ok = file_handle_cache:close(Hdl),
                 Res = parse_segment_entries(SegBin, KeepAcked, Empty),
                 Res
    end.

parse_segment_entries(<<?PUB_PREFIX:?PUB_PREFIX_BITS,
                        IsPersistNum:1, RelSeq:?REL_SEQ_BITS, Rest/binary>>,
                      KeepAcked, Acc) ->
    parse_segment_publish_entry(
      Rest, 1 == IsPersistNum, RelSeq, KeepAcked, Acc);
parse_segment_entries(<<?REL_SEQ_ONLY_PREFIX:?REL_SEQ_ONLY_PREFIX_BITS,
                       RelSeq:?REL_SEQ_BITS, Rest/binary>>, KeepAcked, Acc) ->
    parse_segment_entries(
      Rest, KeepAcked, add_segment_relseq_entry(KeepAcked, RelSeq, Acc));
parse_segment_entries(<<>>, _KeepAcked, Acc) ->
    Acc.

parse_segment_publish_entry(<<Bin:?PUB_RECORD_BODY_BYTES/binary,
                              MsgSize:?EMBEDDED_SIZE_BITS,
                              MsgBin:MsgSize/binary, Rest/binary>>,
                            IsPersistent, RelSeq, KeepAcked,
                            {SegEntries, Unacked}) ->
    Obj = {{IsPersistent, Bin, MsgBin}, no_del, no_ack},
    SegEntries1 = array:set(RelSeq, Obj, SegEntries),
    parse_segment_entries(Rest, KeepAcked, {SegEntries1, Unacked + 1});
parse_segment_publish_entry(Rest, _IsPersistent, _RelSeq, KeepAcked, Acc) ->
    parse_segment_entries(Rest, KeepAcked, Acc).

add_segment_relseq_entry(KeepAcked, RelSeq, {SegEntries, Unacked}) ->
    case array:get(RelSeq, SegEntries) of
        {Pub, no_del, no_ack} ->
            {array:set(RelSeq, {Pub, del, no_ack}, SegEntries), Unacked};
        {Pub, del, no_ack} when KeepAcked ->
            {array:set(RelSeq, {Pub, del, ack},    SegEntries), Unacked - 1};
        {_Pub, del, no_ack} ->
            {array:reset(RelSeq,                   SegEntries), Unacked - 1}
    end.

array_new() ->
    array:new([{default, undefined}, fixed, {size, ?SEGMENT_ENTRY_COUNT}]).

bool_to_int(true ) -> 1;
bool_to_int(false) -> 0.

%%----------------------------------------------------------------------------
%% journal & segment combination
%%----------------------------------------------------------------------------

%% Combine what we have just read from a segment file with what we're
%% holding for that segment in memory. There must be no duplicates.
segment_plus_journal(SegEntries, JEntries) ->
    array:sparse_foldl(
      fun (RelSeq, JObj, {SegEntriesOut, AdditionalUnacked}) ->
              SegEntry = array:get(RelSeq, SegEntriesOut),
              {Obj, AdditionalUnackedDelta} =
                  segment_plus_journal1(SegEntry, JObj),
              {case Obj of
                   undefined -> array:reset(RelSeq, SegEntriesOut);
                   _         -> array:set(RelSeq, Obj, SegEntriesOut)
               end,
               AdditionalUnacked + AdditionalUnackedDelta}
      end, {SegEntries, 0}, JEntries).

%% Here, the result is a tuple with the first element containing the
%% item which we may be adding to (for items only in the journal),
%% modifying in (bits in both), or, when returning 'undefined',
%% erasing from (ack in journal, not segment) the segment array. The
%% other element of the tuple is the delta for AdditionalUnacked.
segment_plus_journal1(undefined, {?PUB, no_del, no_ack} = Obj) ->
    {Obj, 1};
segment_plus_journal1(undefined, {?PUB, del, no_ack} = Obj) ->
    {Obj, 1};
segment_plus_journal1(undefined, {?PUB, del, ack}) ->
    {undefined, 0};

segment_plus_journal1({?PUB = Pub, no_del, no_ack}, {no_pub, del, no_ack}) ->
    {{Pub, del, no_ack}, 0};
segment_plus_journal1({?PUB, no_del, no_ack},       {no_pub, del, ack}) ->
    {undefined, -1};
segment_plus_journal1({?PUB, del, no_ack},          {no_pub, no_del, ack}) ->
    {undefined, -1}.

%% Remove from the journal entries for a segment, items that are
%% duplicates of entries found in the segment itself. Used on start up
%% to clean up the journal.
journal_minus_segment(JEntries, SegEntries) ->
    array:sparse_foldl(
      fun (RelSeq, JObj, {JEntriesOut, UnackedRemoved}) ->
              SegEntry = array:get(RelSeq, SegEntries),
              {Obj, UnackedRemovedDelta} =
                  journal_minus_segment1(JObj, SegEntry),
              {case Obj of
                   keep      -> JEntriesOut;
                   undefined -> array:reset(RelSeq, JEntriesOut);
                   _         -> array:set(RelSeq, Obj, JEntriesOut)
               end,
               UnackedRemoved + UnackedRemovedDelta}
      end, {JEntries, 0}, JEntries).

%% Here, the result is a tuple with the first element containing the
%% item we are adding to or modifying in the (initially fresh) journal
%% array. If the item is 'undefined' we leave the journal array
%% alone. The other element of the tuple is the deltas for
%% UnackedRemoved.

%% Both the same. Must be at least the publish
journal_minus_segment1({?PUB, _Del, no_ack} = Obj, Obj) ->
    {undefined, 1};
journal_minus_segment1({?PUB, _Del, ack} = Obj,    Obj) ->
    {undefined, 0};

%% Just publish in journal
journal_minus_segment1({?PUB, no_del, no_ack},     undefined) ->
    {keep, 0};

%% Publish and deliver in journal
journal_minus_segment1({?PUB, del, no_ack},        undefined) ->
    {keep, 0};
journal_minus_segment1({?PUB = Pub, del, no_ack},  {Pub, no_del, no_ack}) ->
    {{no_pub, del, no_ack}, 1};

%% Publish, deliver and ack in journal
journal_minus_segment1({?PUB, del, ack},           undefined) ->
    {keep, 0};
journal_minus_segment1({?PUB = Pub, del, ack},     {Pub, no_del, no_ack}) ->
    {{no_pub, del, ack}, 1};
journal_minus_segment1({?PUB = Pub, del, ack},     {Pub, del, no_ack}) ->
    {{no_pub, no_del, ack}, 1};

%% Just deliver in journal
journal_minus_segment1({no_pub, del, no_ack},      {?PUB, no_del, no_ack}) ->
    {keep, 0};
journal_minus_segment1({no_pub, del, no_ack},      {?PUB, del, no_ack}) ->
    {undefined, 0};

%% Just ack in journal
journal_minus_segment1({no_pub, no_del, ack},      {?PUB, del, no_ack}) ->
    {keep, 0};
journal_minus_segment1({no_pub, no_del, ack},      {?PUB, del, ack}) ->
    {undefined, -1};

%% Deliver and ack in journal
journal_minus_segment1({no_pub, del, ack},         {?PUB, no_del, no_ack}) ->
    {keep, 0};
journal_minus_segment1({no_pub, del, ack},         {?PUB, del, no_ack}) ->
    {{no_pub, no_del, ack}, 0};
journal_minus_segment1({no_pub, del, ack},         {?PUB, del, ack}) ->
    {undefined, -1};

%% Missing segment. If flush_journal/1 is interrupted after deleting
%% the segment but before truncating the journal we can get these
%% cases: a delivery and an acknowledgement in the journal, or just an
%% acknowledgement in the journal, but with no segment. In both cases
%% we have really forgotten the message; so ignore what's in the
%% journal.
journal_minus_segment1({no_pub, no_del, ack},      undefined) ->
    {undefined, 0};
journal_minus_segment1({no_pub, del, ack},         undefined) ->
    {undefined, 0}.

%%----------------------------------------------------------------------------
%% upgrade
%%----------------------------------------------------------------------------

add_queue_ttl() ->
    foreach_queue_index({fun add_queue_ttl_journal/1,
                         fun add_queue_ttl_segment/1}).

add_queue_ttl_journal(<<?DEL_JPREFIX:?JPREFIX_BITS, SeqId:?SEQ_BITS,
                        Rest/binary>>) ->
    {<<?DEL_JPREFIX:?JPREFIX_BITS, SeqId:?SEQ_BITS>>, Rest};
add_queue_ttl_journal(<<?ACK_JPREFIX:?JPREFIX_BITS, SeqId:?SEQ_BITS,
                        Rest/binary>>) ->
    {<<?ACK_JPREFIX:?JPREFIX_BITS, SeqId:?SEQ_BITS>>, Rest};
add_queue_ttl_journal(<<Prefix:?JPREFIX_BITS, SeqId:?SEQ_BITS,
                        MsgId:?MSG_ID_BYTES/binary, Rest/binary>>) ->
    {[<<Prefix:?JPREFIX_BITS, SeqId:?SEQ_BITS>>, MsgId,
      expiry_to_binary(undefined)], Rest};
add_queue_ttl_journal(_) ->
    stop.

add_queue_ttl_segment(<<?PUB_PREFIX:?PUB_PREFIX_BITS, IsPersistentNum:1,
                        RelSeq:?REL_SEQ_BITS, MsgId:?MSG_ID_BYTES/binary,
                        Rest/binary>>) ->
    {[<<?PUB_PREFIX:?PUB_PREFIX_BITS, IsPersistentNum:1, RelSeq:?REL_SEQ_BITS>>,
      MsgId, expiry_to_binary(undefined)], Rest};
add_queue_ttl_segment(<<?REL_SEQ_ONLY_PREFIX:?REL_SEQ_ONLY_PREFIX_BITS,
                        RelSeq:?REL_SEQ_BITS, Rest/binary>>) ->
    {<<?REL_SEQ_ONLY_PREFIX:?REL_SEQ_ONLY_PREFIX_BITS, RelSeq:?REL_SEQ_BITS>>,
     Rest};
add_queue_ttl_segment(_) ->
    stop.

avoid_zeroes() ->
    foreach_queue_index({none, fun avoid_zeroes_segment/1}).

avoid_zeroes_segment(<<?PUB_PREFIX:?PUB_PREFIX_BITS,  IsPersistentNum:1,
                       RelSeq:?REL_SEQ_BITS, MsgId:?MSG_ID_BITS,
                       Expiry:?EXPIRY_BITS, Rest/binary>>) ->
    {<<?PUB_PREFIX:?PUB_PREFIX_BITS, IsPersistentNum:1, RelSeq:?REL_SEQ_BITS,
       MsgId:?MSG_ID_BITS, Expiry:?EXPIRY_BITS>>, Rest};
avoid_zeroes_segment(<<0:?REL_SEQ_ONLY_PREFIX_BITS,
                       RelSeq:?REL_SEQ_BITS, Rest/binary>>) ->
    {<<?REL_SEQ_ONLY_PREFIX:?REL_SEQ_ONLY_PREFIX_BITS, RelSeq:?REL_SEQ_BITS>>,
     Rest};
avoid_zeroes_segment(_) ->
    stop.

%% At upgrade time we just define every message's size as 0 - that
%% will save us a load of faff with the message store, and means we
%% can actually use the clean recovery terms in VQ. It does mean we
%% don't count message bodies from before the migration, but we can
%% live with that.
store_msg_size() ->
    foreach_queue_index({fun store_msg_size_journal/1,
                         fun store_msg_size_segment/1}).

store_msg_size_journal(<<?DEL_JPREFIX:?JPREFIX_BITS, SeqId:?SEQ_BITS,
                        Rest/binary>>) ->
    {<<?DEL_JPREFIX:?JPREFIX_BITS, SeqId:?SEQ_BITS>>, Rest};
store_msg_size_journal(<<?ACK_JPREFIX:?JPREFIX_BITS, SeqId:?SEQ_BITS,
                        Rest/binary>>) ->
    {<<?ACK_JPREFIX:?JPREFIX_BITS, SeqId:?SEQ_BITS>>, Rest};
store_msg_size_journal(<<Prefix:?JPREFIX_BITS, SeqId:?SEQ_BITS,
                         MsgId:?MSG_ID_BITS, Expiry:?EXPIRY_BITS,
                         Rest/binary>>) ->
    {<<Prefix:?JPREFIX_BITS, SeqId:?SEQ_BITS, MsgId:?MSG_ID_BITS,
       Expiry:?EXPIRY_BITS, 0:?SIZE_BITS>>, Rest};
store_msg_size_journal(_) ->
    stop.

store_msg_size_segment(<<?PUB_PREFIX:?PUB_PREFIX_BITS, IsPersistentNum:1,
                         RelSeq:?REL_SEQ_BITS, MsgId:?MSG_ID_BITS,
                         Expiry:?EXPIRY_BITS, Rest/binary>>) ->
    {<<?PUB_PREFIX:?PUB_PREFIX_BITS, IsPersistentNum:1, RelSeq:?REL_SEQ_BITS,
       MsgId:?MSG_ID_BITS, Expiry:?EXPIRY_BITS, 0:?SIZE_BITS>>, Rest};
store_msg_size_segment(<<?REL_SEQ_ONLY_PREFIX:?REL_SEQ_ONLY_PREFIX_BITS,
                        RelSeq:?REL_SEQ_BITS, Rest/binary>>) ->
    {<<?REL_SEQ_ONLY_PREFIX:?REL_SEQ_ONLY_PREFIX_BITS, RelSeq:?REL_SEQ_BITS>>,
     Rest};
store_msg_size_segment(_) ->
    stop.

store_msg() ->
    foreach_queue_index({fun store_msg_journal/1,
                         fun store_msg_segment/1}).

store_msg_journal(<<?DEL_JPREFIX:?JPREFIX_BITS, SeqId:?SEQ_BITS,
                    Rest/binary>>) ->
    {<<?DEL_JPREFIX:?JPREFIX_BITS, SeqId:?SEQ_BITS>>, Rest};
store_msg_journal(<<?ACK_JPREFIX:?JPREFIX_BITS, SeqId:?SEQ_BITS,
                    Rest/binary>>) ->
    {<<?ACK_JPREFIX:?JPREFIX_BITS, SeqId:?SEQ_BITS>>, Rest};
store_msg_journal(<<Prefix:?JPREFIX_BITS, SeqId:?SEQ_BITS,
                    MsgId:?MSG_ID_BITS, Expiry:?EXPIRY_BITS, Size:?SIZE_BITS,
                    Rest/binary>>) ->
    {<<Prefix:?JPREFIX_BITS, SeqId:?SEQ_BITS, MsgId:?MSG_ID_BITS,
       Expiry:?EXPIRY_BITS, Size:?SIZE_BITS,
       0:?EMBEDDED_SIZE_BITS>>, Rest};
store_msg_journal(_) ->
    stop.

store_msg_segment(<<?PUB_PREFIX:?PUB_PREFIX_BITS, IsPersistentNum:1,
                    RelSeq:?REL_SEQ_BITS, MsgId:?MSG_ID_BITS,
                    Expiry:?EXPIRY_BITS, Size:?SIZE_BITS, Rest/binary>>) ->
    {<<?PUB_PREFIX:?PUB_PREFIX_BITS, IsPersistentNum:1, RelSeq:?REL_SEQ_BITS,
       MsgId:?MSG_ID_BITS, Expiry:?EXPIRY_BITS, Size:?SIZE_BITS,
       0:?EMBEDDED_SIZE_BITS>>, Rest};
store_msg_segment(<<?REL_SEQ_ONLY_PREFIX:?REL_SEQ_ONLY_PREFIX_BITS,
                    RelSeq:?REL_SEQ_BITS, Rest/binary>>) ->
    {<<?REL_SEQ_ONLY_PREFIX:?REL_SEQ_ONLY_PREFIX_BITS, RelSeq:?REL_SEQ_BITS>>,
     Rest};
store_msg_segment(_) ->
    stop.




%%----------------------------------------------------------------------------

foreach_queue_index(Funs) ->
    QueuesDir = queues_dir(),
    QueueDirNames = all_queue_directory_names(QueuesDir),
    {ok, Gatherer} = gatherer:start_link(),
    [begin
         ok = gatherer:fork(Gatherer),
         ok = worker_pool:submit_async(
                fun () ->
                        transform_queue(filename:join(QueuesDir, QueueDirName),
                                        Gatherer, Funs)
                end)
     end || QueueDirName <- QueueDirNames],
    empty = gatherer:out(Gatherer),
    unlink(Gatherer),
    ok = gatherer:stop(Gatherer).

transform_queue(Dir, Gatherer, {JournalFun, SegmentFun}) ->
    ok = transform_file(filename:join(Dir, ?JOURNAL_FILENAME), JournalFun),
    [ok = transform_file(filename:join(Dir, Seg), SegmentFun)
     || Seg <- rabbit_file:wildcard(".*\\" ++ ?SEGMENT_EXTENSION, Dir)],
    ok = gatherer:finish(Gatherer).

transform_file(_Path, none) ->
    ok;
transform_file(Path, Fun) when is_function(Fun)->
    PathTmp = Path ++ ".upgrade",
    case rabbit_file:file_size(Path) of
        0    -> ok;
        Size -> {ok, PathTmpHdl} =
                    file_handle_cache:open(PathTmp, ?WRITE_MODE,
                                           [{write_buffer, infinity}]),

                {ok, PathHdl} = file_handle_cache:open(
                                  Path, ?READ_MODE, [{read_buffer, Size}]),
                {ok, Content} = file_handle_cache:read(PathHdl, Size),
                ok = file_handle_cache:close(PathHdl),

                ok = drive_transform_fun(Fun, PathTmpHdl, Content),

                ok = file_handle_cache:close(PathTmpHdl),
                ok = rabbit_file:rename(PathTmp, Path)
    end.

drive_transform_fun(Fun, Hdl, Contents) ->
    case Fun(Contents) of
        stop                -> ok;
        {Output, Contents1} -> ok = file_handle_cache:append(Hdl, Output),
                               drive_transform_fun(Fun, Hdl, Contents1)
    end.
