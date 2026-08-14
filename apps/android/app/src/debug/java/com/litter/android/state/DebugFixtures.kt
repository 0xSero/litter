package com.litter.android.state
import android.content.Intent
import android.os.SystemClock
import com.litter.android.util.LLog
import kotlinx.coroutines.*
import uniffi.codex_mobile_client.*
/** W1 (perf-0b) DEBUG-only measurement seams — Android half of the iOS W1 #if DEBUG additions: deterministic production
 * fixture (default 300 sessions / 1500 items, iOS six-case cycle), A-8 burst driver, A-1 ingress ring (512 + eviction), A-9 watchdog, A-10 beacon; debug source set only. */
object DebugFixtures : AppModelDebugPerfHooks {
    private const val TAG = "burst"; private const val EPOCH = 1_700_000_000L; private const val SERVER_ID = "fixture-server"
    private const val LIVE_ASSISTANT_ITEM_ID = "fixture-live-assistant-1" // thread-1 only (foreign stream)
    private const val BURST_ITEM_ID = "fixture-item-1" // assistant item on displayed thread-0
    const val EXTRA_FIXTURE_SESSIONS = "litter.debug.fixtureSessions"; const val EXTRA_FIXTURE_ITEMS = "litter.debug.fixtureItems"
    const val EXTRA_STREAM_FOREIGN_MS = "litter.debug.streamForeignMs"; const val EXTRA_BURST_TIMINGS_MS = "litter.debug.burstTimingsMs"; const val EXTRA_BURST_NONCE = "litter.debug.burstNonce"
    const val T0_PROMPT = "Run the command sh -c 'for i in 1 2 3 4 5 6 7 8; do echo tick \$i; sleep 1; done' and then summarize its output in one sentence."
    const val T0_LONG_PROMPT = "Run the command sh -c 'for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do echo tick \$i; sleep 1; done' and then summarize its output in one sentence."
    val fixtureThreadKey = ThreadKey(SERVER_ID, "fixture-thread-0"); val liveThreadKey = ThreadKey(SERVER_ID, "fixture-thread-1")
    private val INPUT_REGEX = Regex("^B([1-9][0-9]{0,2})\\.([1-9][0-9]?)-(PLAIN|STEER)-([0-9a-f]{6})$")
    class BurstInput(val raw: String, val trial: String, val attempt: String, val steer: Boolean, val hex: String) { fun wire(k: Int) = "B$trial.$attempt-F$k-$hex" }
    /** Pure grammar gate (Fable W1 amendment): absent ⇒ silent idle; no trim/case-fold/fallback. */
    fun parseBurstInput(raw: String?): BurstInput? {
        val raw = raw ?: return null; val g = INPUT_REGEX.matchEntire(raw)?.groupValues ?: return null
        return BurstInput(raw, g[1], g[2], g[3] == "STEER", g[4])
    }
    fun rejectionLine(raw: String?, parsed: BurstInput? = parseBurstInput(raw)): String? = when { raw == null || parsed != null -> null; raw.isEmpty() -> "burst.driver reject reason=missing-nonce"; else -> "burst.driver reject reason=malformed-nonce value=\"$raw\"" } // absent/valid ⇒ null; bootstrap reuses its single parse
    fun followUpTexts(input: BurstInput) = listOf(
        "Follow-up one ${input.wire(1)}: reply with exactly ALPHA.",
        "Follow-up two ${input.wire(2)}: reply with exactly " + (if (input.steer) "BRAVO-STEERED." else "BRAVO."),
        "Follow-up three ${input.wire(3)}: reply with exactly CHARLIE.",
    )
    /** Exactly three positional fire offsets; each slot falls back to its own default when missing/invalid; clamped 10..2000 ms. */
    fun parseTimings(raw: String?): List<Long> {
        val slots = raw?.split(','); val defaults = listOf(200L, 400L, 700L)
        return List(3) { i -> (slots?.getOrNull(i)?.trim()?.toLongOrNull() ?: defaults[i]).coerceIn(10L, 2_000L) }
    }
    fun burstPlan(offsetsMs: List<Long>, anchorMonoMs: Long): List<Pair<Int, Long>> = offsetsMs.mapIndexed { index, offset -> index to anchorMonoMs + offset }.sortedWith(compareBy({ it.second }, { it.first }))
    /** One-shot evidence checkpoint: max(lastFire+1s, anchorWindow+8s); never polls queue state. */
    fun checkpointDelayMs(offsetsMs: List<Long>, anchorIsLong: Boolean): Long = maxOf((offsetsMs.maxOrNull() ?: 0L) + 1_000L, (if (anchorIsLong) 20_000L else 8_000L) + 8_000L)
    fun itemAt(i: Int) = HydratedConversationItem("fixture-item-$i", when (i % 6) {
        0 -> HydratedConversationItemContent.User(HydratedUserMessageData("Fixture user message $i.", emptyList()))
        1 -> HydratedConversationItemContent.Assistant(HydratedAssistantMessageData("Fixture assistant reply $i.", null, null, AppMessagePhase.FINAL_ANSWER))
        2 -> HydratedConversationItemContent.Reasoning(HydratedReasoningData(listOf("Fixture reasoning $i."), emptyList()))
        3 -> HydratedConversationItemContent.CommandExecution(HydratedCommandExecutionData("echo fixture-$i", "/Projects/Workspace-${i % 12}", AppOperationStatus.COMPLETED, "fixture output $i", 0, 120, null, emptyList()))
        4 -> HydratedConversationItemContent.McpToolCall(HydratedMcpToolCallData("fixture-mcp", "fixtureTool", AppOperationStatus.COMPLETED, 80, "{}", "Fixture tool summary $i.", null, null, null, emptyList(), null))
        else -> HydratedConversationItemContent.CommandExecution(HydratedCommandExecutionData("sleep ${i % 3 + 1}", "/Projects/Workspace-${i % 12}", AppOperationStatus.IN_PROGRESS, null, null, null, null, emptyList()))
    }, "fixture-turn-${i / 6}", (i % 6).toUInt(), (EPOCH + i).toDouble(), i % 6 == 0)
    private fun thread(i: Int, items: List<HydratedConversationItem>) = AppThreadSnapshot(
        ThreadKey(SERVER_ID, "fixture-thread-$i"),
        ThreadInfo("fixture-thread-$i", "Fixture thread $i", "gpt-fixture", ThreadSummaryStatus.IDLE, "Fixture preview $i", "/Projects/Workspace-${i / 25}", null, "openai", null, null, if (i > 0 && i % 10 == 9) "fixture-thread-${i - 9}" else null, null, null, EPOCH - i - 3_600L, EPOCH - i),
        "codex", AppModeKind.DEFAULT, "gpt-fixture", null, null, null, items, emptyList(), null, null, null, null, null, null, null, null, null, null, null, true)
    private fun summary(key: ThreadKey, updatedAt: Long, active: Boolean, parent: String? = null, title: String = "Fixture thread", preview: String = "Fixture preview", cwd: String = "/Projects/Workspace-0") = AppSessionSummary(key, "codex", "Fixture Studio", "fixture.local", title, preview, cwd, "gpt-fixture", "openai", parent, null, null, null, key.threadId, AppSubagentStatus.UNKNOWN, updatedAt, active, false, false, false, null, null, null, null, emptyList(), null, null, null, null, null)
    fun makeSnapshot(sessions: Int, items: Int): AppSnapshotRecord {
        val threads = (0 until maxOf(sessions, 2)).map { i ->
            thread(i, when (i) {
                0 -> (0 until maxOf(items, 0)).map(::itemAt)
                1 -> listOf(
                    HydratedConversationItem("fixture-live-user-1", HydratedConversationItemContent.User(HydratedUserMessageData("Fixture live turn.", emptyList())), "fixture-live-turn", 0u, (EPOCH + 10).toDouble(), true),
                    HydratedConversationItem(LIVE_ASSISTANT_ITEM_ID, HydratedConversationItemContent.Assistant(HydratedAssistantMessageData("Fixture live stream.", null, null, AppMessagePhase.COMMENTARY)), "fixture-live-turn", 1u, (EPOCH + 11).toDouble(), false),
                    HydratedConversationItem("fixture-live-assistant-2", HydratedConversationItemContent.Assistant(HydratedAssistantMessageData("Done.", null, null, AppMessagePhase.FINAL_ANSWER)), "fixture-live-turn", 2u, (EPOCH + 12).toDouble(), false))
                else -> emptyList()
            })
        }
        val server = AppServerSnapshot(SERVER_ID, "Fixture Studio", "fixture.local", 8390u, null, false, AppServerHealth.CONNECTED, AppServerTransportState.CONNECTED, AppServerCapabilities(true, true, true, true, false), null, false, null, emptyList(), null, listOf(AgentRuntimeInfo("codex", "codex", "Codex", true)), null, null)
        return AppSnapshotRecord(listOf(server), threads, threads.map { summary(it.key, it.info.updatedAt ?: EPOCH, it.activeTurnId != null, it.info.parentThreadId, it.info.title ?: "", it.info.preview ?: "", it.info.cwd ?: "") }, 0uL, null, emptyList(), emptyList(), AppVoiceSessionSnapshot(null, null, null, null, emptyList(), null), emptyList(), null)
    }
    private fun burstState(key: ThreadKey, status: ThreadSummaryStatus, activeTurnId: String?, queued: List<AppQueuedFollowUpPreview>) = AppThreadStateRecord(key, ThreadInfo(key.threadId, "Fixture thread", "gpt-fixture", status, "Fixture preview", "/Projects/Workspace-0", null, "openai", null, null, null, null, null, EPOCH, EPOCH), "codex", AppModeKind.DEFAULT, "gpt-fixture", null, null, null, queued, activeTurnId, null, null, null, null, null, null, null, null, true)
    /** Fixture-mode synthesized burst: queue grows per fire; the delta hits BURST_ITEM_ID on displayed thread-0. */
    fun burstUpdates(index: Int, key: ThreadKey, texts: List<String>): List<AppStoreUpdateRecord> {
        val queued = texts.take(index + 1).mapIndexed { j, text -> AppQueuedFollowUpPreview("fixture-burst-followup-$j", AppQueuedFollowUpKind.MESSAGE, text) }
        return listOf(
            AppStoreUpdateRecord.ThreadMetadataChanged(burstState(key, ThreadSummaryStatus.ACTIVE, "fixture-burst-turn", queued), summary(key, EPOCH, true), 0uL),
            AppStoreUpdateRecord.ThreadStreamingDelta(key, BURST_ITEM_ID, ThreadStreamingDeltaKind.ASSISTANT_TEXT, " F${index + 1} burst δ"))
    }
    fun burstDrainUpdate(key: ThreadKey): AppStoreUpdateRecord = AppStoreUpdateRecord.ThreadMetadataChanged(burstState(key, ThreadSummaryStatus.IDLE, null, emptyList()), summary(key, EPOCH + 1, false), 0uL)
    /** A-8 burst driver: one-shot IDLE→ARMED→FIRED latch anchored at the startTurn invocation instant. */
    class BurstDriver(val offsetsMs: List<Long>, val input: BurstInput, val fixtureMode: Boolean) {
        enum class Phase { IDLE, ARMED, FIRED }
        var phase = Phase.IDLE; var anchorMonoMs = 0L; var anchorIsLong = false
        private val followUps = followUpTexts(input)
        fun arm() { if (phase == Phase.IDLE) phase = Phase.ARMED }
        fun isFollowUpText(text: String) = followUps.contains(text); fun isAnchorPrompt(text: String) = text == T0_PROMPT || text == T0_LONG_PROMPT
        fun onStartTurnEntered(text: String, nowMonoMs: Long): List<Pair<Int, Long>>? {
            if (phase != Phase.ARMED || !isAnchorPrompt(text)) return null
            phase = Phase.FIRED; anchorMonoMs = nowMonoMs; anchorIsLong = text == T0_LONG_PROMPT; return burstPlan(offsetsMs, nowMonoMs)
        }
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); private val ledger = ArrayDeque<String>(); private var droppedSinceFlush = 0
    private var watchdogJob: Job? = null; private var foreignStreamJob: Job? = null; private var hookedModel: AppModel? = null; private var armedDriver: BurstDriver? = null
    private fun monoMs() = SystemClock.uptimeMillis()
    internal fun appendLedger(line: String) = synchronized(ledger) { // A-1 ring: cap 512, overwrite-on-full, evictions counted since last flush
        ledger.addLast(line); if (ledger.size > 512) { ledger.removeFirst(); droppedSinceFlush++ }
    }
    /** LEDGER_FLUSH_LAW: emit header + captured entries first; clear exactly the emitted batch; never clear on emit failure. */
    fun flushLedger(reason: String, emit: (String) -> Unit = { LLog.i(TAG, it) }) {
        synchronized(ledger) {
            val batch = ledger.toList(); val dropped = droppedSinceFlush; if (batch.isEmpty() && dropped == 0) return
            try { emit("burst.ledger flush reason=$reason entries=${batch.size} dropped=$dropped"); batch.forEach(emit) } catch (_: Throwable) { return }
            repeat(batch.size) { ledger.removeFirst() }; droppedSinceFlush = 0
        }
    }
    /** A-1 post-apply ingress: mono + wall, variant, full ThreadKey, queued count, steer kinds, active turn, revision. */
    override fun onStoreUpdateApplied(update: AppStoreUpdateRecord) {
        var k: ThreadKey? = null; var queued: List<AppQueuedFollowUpPreview>? = null; var active: String? = null
        when (update) {
            is AppStoreUpdateRecord.ThreadUpserted -> { k = update.thread.key; queued = update.thread.queuedFollowUps; active = update.thread.activeTurnId }
            is AppStoreUpdateRecord.ThreadMetadataChanged -> { k = update.state.key; queued = update.state.queuedFollowUps; active = update.state.activeTurnId }
            is AppStoreUpdateRecord.ThreadItemChanged -> k = update.key; is AppStoreUpdateRecord.ThreadStreamingDelta -> k = update.key
            is AppStoreUpdateRecord.DynamicWidgetStreaming -> k = update.key; is AppStoreUpdateRecord.ThreadRemoved -> k = update.key
            is AppStoreUpdateRecord.ActiveThreadChanged -> k = update.key; else -> {}
        }
        if (queued == null && k != null) { val t = hookedModel?.debugCachedThreadSnapshot(k); queued = t?.queuedFollowUps; if (active == null) active = t?.activeTurnId }
        appendLedger("burst.ingress mono=${monoMs()} wall=${System.currentTimeMillis()} variant=${update::class.simpleName} key=${k?.serverId ?: "-"}/${k?.threadId ?: "-"} queued=${queued?.size ?: "-"} steer=${steerKinds(queued)} activeTurn=${active ?: "-"} rev=${if (update is AppStoreUpdateRecord.ActiveThreadChanged || k == null) (hookedModel?.conversationGlobalRevision?.value ?: -1L) else (hookedModel?.threadRevision(k!!)?.value ?: -1L)}")
    }
    private fun steerKinds(p: List<AppQueuedFollowUpPreview>?) = "${p?.count { it.kind == AppQueuedFollowUpKind.MESSAGE } ?: "-"}/${p?.count { it.kind == AppQueuedFollowUpKind.PENDING_STEER } ?: "-"}/${p?.count { it.kind == AppQueuedFollowUpKind.RETRYING_STEER } ?: "-"}"
    private fun startWatchdog() { // A-9: 250 ms heartbeat; gaps > 500 ms land in the ring (mono + wall)
        if (watchdogJob != null) return
        watchdogJob = scope.launch(Dispatchers.Main) { var last = monoMs(); while (isActive) { delay(250); val now = monoMs(); val gap = now - last; last = now; if (gap > 500) appendLedger("burst.watchdog gapMs=$gap mono=$now wall=${System.currentTimeMillis()}") } }
    }
    private fun startForeignStream(appModel: AppModel, cadenceMs: Long) { // foreign deltas stay on thread-1's live assistant item (apply seam, no RPC)
        if (cadenceMs <= 0 || foreignStreamJob != null) return
        foreignStreamJob = scope.launch { var n = 0; while (isActive) { delay(cadenceMs); n++; appModel.debugInjectStoreUpdate(AppStoreUpdateRecord.ThreadStreamingDelta(liveThreadKey, LIVE_ASSISTANT_ITEM_ID, ThreadStreamingDeltaKind.ASSISTANT_TEXT, " fδ$n")) } }
    }
    override fun onStartTurnEntered(key: ThreadKey, text: String) {
        val d = armedDriver ?: return
        if (d.phase == BurstDriver.Phase.FIRED && d.isFollowUpText(text)) LLog.i(TAG, "burst.driver follow-up entry (recursion-guarded)")
        val plan = d.onStartTurnEntered(text, monoMs()) ?: return
        LLog.i(TAG, "burst.driver armed->fired anchorMonoMs=${d.anchorMonoMs} key=${key.serverId}/${key.threadId} wall=${System.currentTimeMillis()}")
        scheduleFires(hookedModel ?: return, d, key, plan)
    }
    override fun onFlushLedger(reason: String) = flushLedger(reason)
    private fun scheduleFires(appModel: AppModel, driver: BurstDriver, key: ThreadKey, plan: List<Pair<Int, Long>>) {
        val texts = followUpTexts(driver.input)
        val firesJob = if (driver.fixtureMode) scope.launch {
            plan.forEach { (index, intended) -> // serialized canonical order: intended timestamp, then index
                delay((intended - monoMs()).coerceAtLeast(0L)); val actual = monoMs()
                LLog.i(TAG, "burst.driver fire F${index + 1} intended=$intended actual=$actual drift=${actual - intended} nonce=${driver.input.wire(index + 1)} wall=${System.currentTimeMillis()}")
                appModel.debugBeaconVisibleUntilMs = monoMs() + 66
                burstUpdates(index, key, texts).forEach { appModel.debugInjectStoreUpdate(it) }
            }
        } else null
        if (!driver.fixtureMode) for ((index, intended) in plan) scope.launch { // live: independent per-fire Jobs
            delay((intended - driver.anchorMonoMs).coerceAtLeast(0L)); val actual = monoMs()
            LLog.i(TAG, "burst.driver fire F${index + 1} intended=$intended actual=$actual drift=${actual - intended} nonce=${driver.input.wire(index + 1)} wall=${System.currentTimeMillis()}")
            appModel.debugBeaconVisibleUntilMs = monoMs() + 66
            appModel.startTurn(key, AppComposerPayload(text = texts[index]))
        }
        if (driver.fixtureMode) scope.launch {
            delay((driver.anchorMonoMs + (if (driver.anchorIsLong) 20_000L else 8_000L) + 500L - monoMs()).coerceAtLeast(0L)); firesJob?.join() // T0 window completion, then drain
            LLog.i(TAG, "burst.t0Completed mono=${monoMs()} wall=${System.currentTimeMillis()}")
            appModel.debugInjectStoreUpdate(burstDrainUpdate(key))
        }
        val cp = checkpointDelayMs(driver.offsetsMs, driver.anchorIsLong); scope.launch { delay(cp); flushLedger("checkpoint"); LLog.i(TAG, "burst.driver checkpoint delayMs=$cp wall=${System.currentTimeMillis()}") }
    }
    /** W1 entry point; reflectively called by MainActivity in DEBUG builds. True ⇒ fixture mode owns the snapshot; the armed driver waits for the real startTurn T0/T0_LONG anchor hook (startTurn returns before any RPC). */
    @JvmStatic
    fun bootstrap(intent: Intent, appModel: AppModel): Boolean {
        val sessions = intent.getIntExtra(EXTRA_FIXTURE_SESSIONS, -1); val items = intent.getIntExtra(EXTRA_FIXTURE_ITEMS, -1)
        val fixtureRequested = sessions >= 0 || items >= 0; val rawNonce = intent.getStringExtra(EXTRA_BURST_NONCE)
        hookedModel = appModel; appModel.debugInstallPerfHooks(this)
        val input = parseBurstInput(rawNonce)
        rejectionLine(rawNonce, input)?.let { LLog.i(TAG, it) }
        input?.let { inp ->
            BurstDriver(parseTimings(intent.getStringExtra(EXTRA_BURST_TIMINGS_MS)), inp, fixtureRequested).also { d ->
                d.arm(); armedDriver = d
                LLog.i(TAG, "burst.driver idle->armed offsets=${d.offsetsMs.joinToString(",")} input=${inp.raw} trial=${inp.trial} attempt=${inp.attempt} steer=${if (inp.steer) "STEER" else "PLAIN"} hex=${inp.hex} mode=${if (fixtureRequested) "fixture" else "live"}")
            }
        }
        if (fixtureRequested) {
            appModel.debugApplyFixtureSnapshot(makeSnapshot(if (sessions >= 0) sessions else 300, if (items >= 0) items else 1500))
            startForeignStream(appModel, intent.getStringExtra(EXTRA_STREAM_FOREIGN_MS)?.let { raw -> if (raw == "1") 100L else raw.toLongOrNull() ?: 100L } ?: 0L)
        }
        startWatchdog()
        return fixtureRequested
    }
}
