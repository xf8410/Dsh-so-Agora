# 06:42:11 · 附件2 of 4 — UmaWorkbenchService.kt 原文

（来源：Transfer Dock_Text_20261104063805.txt）

1	package com.newoether.agora.uma
     2	
     3	import android.app.NotificationChannel
     4	import android.app.NotificationManager
     5	import android.app.PendingIntent
     6	import android.app.Service
     7	import android.content.Context
     8	import android.content.Intent
     9	import android.graphics.Color
    10	import android.graphics.PixelFormat
    11	import android.os.Build
    12	import android.os.IBinder
    13	import android.provider.Settings
    14	import android.view.Gravity
    15	import android.view.MotionEvent
    16	import android.view.View
    17	import android.view.WindowManager
    18	import android.widget.LinearLayout
    19	import android.widget.TextView
    20	import androidx.core.app.NotificationCompat
    21	import com.newoether.agora.AgoraApplication
    22	import com.newoether.agora.MainActivity
    23	import com.newoether.agora.R
    24	import com.newoether.agora.automation.TaskExecutionEngine
    25	import com.newoether.agora.data.local.ChatEntity
    26	import java.net.HttpURLConnection
    27	import java.net.URL
    28	import java.util.UUID
    29	import java.util.concurrent.atomic.AtomicBoolean
    30	import kotlinx.coroutines.CoroutineScope
    31	import kotlinx.coroutines.Dispatchers
    32	import kotlinx.coroutines.Job
    33	import kotlinx.coroutines.SupervisorJob
    34	import kotlinx.coroutines.cancel
    35	import kotlinx.coroutines.delay
    36	import kotlinx.coroutines.isActive
    37	import kotlinx.coroutines.launch
    38	import kotlinx.coroutines.withContext
    39	import org.json.JSONObject
    40	
    41	/** Agora-native Uma monitor and bounded headless-analysis coordinator. */
    42	class UmaWorkbenchService : Service() {
    43	    companion object {
    44	        private const val CHANNEL = "agora_uma_workbench"
    45	        private const val NOTIFICATION = 18765
    46	        private const val PREFS = "uma_workbench"
    47	        private const val KEY_AUTO = "auto_analyze"
    48	        private const val KEY_CAPTURE_DESIRED = "protocol_capture_desired"
    49	        private const val KEY_CONVERSATION = "conversation_id"
    50	        private const val KEY_LAST_ANALYZED = "last_analyzed_signature"
    51	        private const val MIN_ANALYSIS_INTERVAL_MS = 20_000L
    52	        const val ACTION_START = "com.newoether.agora.uma.START"
    53	        const val ACTION_STOP = "com.newoether.agora.uma.STOP"
    54	        const val ACTION_REFRESH = "com.newoether.agora.uma.REFRESH"
    55	        const val ACTION_ANALYZE = "com.newoether.agora.uma.ANALYZE"
    56	        const val ACTION_TOGGLE_AUTO = "com.newoether.agora.uma.TOGGLE_AUTO"
    57	        const val ACTION_TOGGLE_CAPTURE = "com.newoether.agora.uma.TOGGLE_CAPTURE"
    58	
    59	        fun start(context: Context) {
    60	            val i = Intent(context, UmaWorkbenchService::class.java).setAction(ACTION_START)
    61	            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(i) else context.startService(i)
    62	        }
    63	        fun stop(context: Context) {
    64	            context.startService(Intent(context, UmaWorkbenchService::class.java).setAction(ACTION_STOP))
    65	        }
    66	    }
    67	
    68	    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    69	    private val analyzing = AtomicBoolean(false)
    70	    private val captureRequestInFlight = AtomicBoolean(false)
    71	    private val prefs by lazy { getSharedPreferences(PREFS, MODE_PRIVATE) }
    72	    private var monitorJob: Job? = null
    73	    private var windowManager: WindowManager? = null
    74	    private var overlay: View? = null
    75	    private var statusText: TextView? = null
    76	    private var captureButton: TextView? = null
    77	    private var lastSignature = ""
    78	    private var latestDisplay = "Uma Workbench\n正在连接 SO…"
    79	    private var lastAnalysisAt = 0L
    80	    @Volatile private var soConnected = false
    81	    @Volatile private var captureEnabledForConnection = false
    82	
    83	    override fun onCreate() {
    84	        super.onCreate()
    85	        createChannel()
    86	        startForeground(NOTIFICATION, notification("等待连接 127.0.0.1:18765"))
    87	        if (Settings.canDrawOverlays(this)) showOverlay()
    88	        startMonitor()
    89	        refreshCaptureUi()
    90	    }
    91	
    92	    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    93	        when (intent?.action) {
    94	            ACTION_STOP -> {
    95	                prefs.edit().putBoolean(KEY_CAPTURE_DESIRED, false).apply()
    96	                scope.launch {
    97	                    runCatching { UmaProtocolCapture.setEnabled(false) }
    98	                    stopSelf()
    99	                }
   100	                return START_NOT_STICKY
   101	            }
   102	            ACTION_REFRESH -> scope.launch { pollOnce(true) }
   103	            ACTION_ANALYZE -> scope.launch { analyzeNow(manual = true) }
   104	            ACTION_TOGGLE_AUTO -> {
   105	                prefs.edit().putBoolean(KEY_AUTO, !prefs.getBoolean(KEY_AUTO, false)).apply()
   106	                updateStatus(latestDisplay, notificationLabel())
   107	            }
   108	            ACTION_TOGGLE_CAPTURE -> toggleCaptureDesired()
   109	            else -> {
   110	                if (overlay == null && Settings.canDrawOverlays(this)) showOverlay()
   111	                startMonitor()
   112	            }
   113	        }
   114	        return START_STICKY
   115	    }
   116	
   117	    private fun toggleCaptureDesired() {
   118	        val desired = !prefs.getBoolean(KEY_CAPTURE_DESIRED, false)
   119	        prefs.edit().putBoolean(KEY_CAPTURE_DESIRED, desired).apply()
   120	        refreshCaptureUi()
   121	        if (desired) {
   122	            // ARMED mode: if the game/SO is not ready yet, the monitor retries after connection.
   123	            requestCaptureState(true)
   124	        } else {
   125	            requestCaptureState(false)
   126	        }
   127	    }
   128	
   129	    private fun requestCaptureState(enabled: Boolean) {
   130	        if (!captureRequestInFlight.compareAndSet(false, true)) return
   131	        scope.launch {
   132	            try {
   133	                UmaProtocolCapture.setEnabled(enabled)
   134	                soConnected = true
   135	                captureEnabledForConnection = enabled
   136	            } catch (_: Exception) {
   137	                if (enabled) {
   138	                    // Keep the user intent armed. A later successful /summary poll retries it.
   139	                    soConnected = false
   140	                    captureEnabledForConnection = false
   141	                }
   142	            } finally {
   143	                captureRequestInFlight.set(false)
   144	                refreshCaptureUi()
   145	            }
   146	        }
   147	    }
   148	
   149	    private fun startMonitor() {
   150	        if (monitorJob?.isActive == true) return
   151	        monitorJob = scope.launch {
   152	            // 断连退避：游戏切后台 SO 必断，2s 硬轮询只会刷屏+耗电。
   153	            // 连续失败按 2→4→8→16→30s（封顶）退避；一旦连上立刻回 2s 快速档。
   154	            var backoffMs = 2_000L
   155	            while (isActive) {
   156	                val ok = pollOnce(false)
   157	                if (!ok) {
   158	                    backoffMs = minOf(backoffMs * 2, 30_000L)
   159	                } else {
   160	                    backoffMs = 2_000L
   161	                }
   162	                delay(backoffMs)
   163	            }
   164	        }
   165	    }
   166	
   167	    /** 返回本次轮询是否成功（退避节奏用；实现内部的 UI 更新语义不变）。 */
   168	    private suspend fun pollOnce(force: Boolean): Boolean {
   169	        val raw = runCatching { httpGet("/summary", 512 * 1024) }.getOrElse {
   170	            soConnected = false
   171	            captureEnabledForConnection = false
   172	            refreshCaptureUi()
   173	            updateStatus("SO 未连接\n${it.message ?: "18765 无响应"}", "SO 未连接")
   174	            return false
   175	        }
   176	        soConnected = true
   177	        if (prefs.getBoolean(KEY_CAPTURE_DESIRED, false) && !captureEnabledForConnection) {
   178	            requestCaptureState(true)
   179	        }
   180	        refreshCaptureUi()
   181	        val changes = runCatching { UmaRuntimeState.update(raw) }.getOrElse {
   182	            // ③ 竞态修复：解析失败不算连上——回滚状态，让 ARMED 恢复链下轮重走
   183	            soConnected = false
   184	            captureEnabledForConnection = false
   185	            refreshCaptureUi()
   186	            updateStatus("SO 响应解析失败\n${it.message}", "响应解析失败")
   187	            return false
   188	        }
   189	        val summary = JSONObject(raw)
   190	        val signature = listOf(
   191	            summary.optInt("turn", -1), summary.optInt("month", -1), summary.optInt("half", -1),
   192	            summary.optString("scenario", ""), summary.optJSONObject("stats")?.toString().orEmpty(),
   193	            summary.optJSONArray("trainings")?.toString().orEmpty(),
   194	        ).joinToString("|")
   195	        if (!force && signature == lastSignature) return true
   196	        lastSignature = signature
   197	        latestDisplay = formatSummary(summary)
   198	        updateStatus(latestDisplay, notificationLabel())
   199	
   200	        val changed = changes.optJSONArray("changed")
   201	        val meaningful = changes.optBoolean("meaningful", false)
   202	        val trigger = changed?.let { arr ->
   203	            (0 until arr.length()).map { arr.optString(it) }.any {
   204	                it in setOf("turn", "month", "half", "scenario", "trainings", "initial_snapshot")
   205	            }
   206	        } == true
   207	        if (prefs.getBoolean(KEY_AUTO, false) && meaningful && trigger &&
   208	            signature != prefs.getString(KEY_LAST_ANALYZED, "") &&
   209	            System.currentTimeMillis() - lastAnalysisAt >= MIN_ANALYSIS_INTERVAL_MS) {
   210	            analyzeNow(manual = false)
   211	        }
   212	        return true
   213	    }
   214	
   215	    private fun formatSummary(summary: JSONObject): String {
   216	        val turn = summary.optInt("turn", -1)
   217	        val scenario = summary.optString("scenario", "").ifBlank { "育成" }
   218	        val stats = summary.optJSONObject("stats")
   219	        val line = if (stats != null) "速${stats.optInt("speed")} 耐${stats.optInt("stamina")} " +
   220	            "力${stats.optInt("power")} 根${stats.optInt("guts")} 智${stats.optInt("wiz")}" else "已读取 summary"
   221	        return "SO ●  $scenario${if (turn >= 0) "  T$turn" else ""}\n$line\n" +
   222	            "自动:${if (prefs.getBoolean(KEY_AUTO, false)) "开" else "关"} · 点状态打开 Agora · 长按拖动"
   223	    }
   224	
   225	    private suspend fun analyzeNow(manual: Boolean) {
   226	        if (!analyzing.compareAndSet(false, true)) return
   227	        try {
   228	            lastAnalysisAt = System.currentTimeMillis()
   229	            updateStatus("$latestDisplay\nAI 分析中…", "AI 分析中")
   230	            val app = application as AgoraApplication
   231	            val container = app.container
   232	            val conversationId = ensureConversation(container)
   233	            val changes = UmaRuntimeState.changesJson().take(4_096)
   234	            val prompt = """
   235	                赛马娘 SO 状态发生变化。请使用 Agora 内置 uma_get_snapshot，必要时使用全部 uma_* 工具分析当前状态。
   236	                当前结构变化：$changes
   237	                遵守证据等级：[MDB] / [截图确认] / [代码确认] / [候选] / [unknown]。禁止猜测。可使用全部 uma_* 工具，包括 sniff、raw 数据、/scan、/il2cpp/classes 和递归 dump。
   238	                输出简短：当前事实、可信结论、未知项、下一步需要等待的游戏操作或定点类查询。
   239	            """.trimIndent()
   240	            when (val result = container.taskExecutionEngine.runOnce(
   241	                conversationId = conversationId,
   242	                userText = prompt,
   243	                foregroundServiceManagedExternally = true,
   244	            )) {
   245	                is TaskExecutionEngine.Result.Success -> {
   246	                    prefs.edit().putString(KEY_LAST_ANALYZED, lastSignature).apply()
   247	                    val compact = result.text.replace('\n', ' ').take(160)
   248	                    updateStatus("$latestDisplay\nAI：$compact", "AI 分析完成")
   249	                }
   250	                is TaskExecutionEngine.Result.Failure -> updateStatus(
   251	                    "$latestDisplay\nAI 失败：${result.reason.take(120)}", "AI 分析失败")
   252	            }
   253	        } catch (e: Exception) {
   254	            updateStatus("$latestDisplay\nAI 失败：${e.message?.take(120)}", "AI 分析失败")
   255	        } finally { analyzing.set(false) }
   256	    }
   257	
   258	    private suspend fun ensureConversation(container: com.newoether.agora.di.AppContainer): String {
   259	        val saved = prefs.getString(KEY_CONVERSATION, null)
   260	        if (!saved.isNullOrBlank() && container.conversationRepository.getConversation(saved) != null) return saved
   261	        val id = UUID.randomUUID().toString()
   262	        container.conversationRepository.upsertConversation(ChatEntity(
   263	            id = id,
   264	            title = "赛马娘自动分析",
   265	            modelId = container.settingsRepository.selectedModel.value,
   266	            origin = "user",
   267	            graduated = true,
   268	        ))
   269	        prefs.edit().putString(KEY_CONVERSATION, id).apply()
   270	        return id
   271	    }
   272	
   273	    private suspend fun httpGet(path: String, maxChars: Int): String = withContext(Dispatchers.IO) {
   274	        val c = URL("http://127.0.0.1:18765$path").openConnection() as HttpURLConnection
   275	        try {
   276	            c.connectTimeout = 1_500; c.readTimeout = 3_000; c.useCaches = false
   277	            if (c.responseCode != 200) error("HTTP ${c.responseCode}")
   278	            c.inputStream.bufferedReader(Charsets.UTF_8).use { r ->
   279	                val out = StringBuilder(minOf(maxChars, 8_192)); val buf = CharArray(2_048)
   280	                while (true) { val n = r.read(buf); if (n < 0) break
   281	                    if (out.length + n > maxChars) error("响应超过 ${maxChars / 1024} KiB")
   282	                    out.append(buf, 0, n) }
   283	                out.toString()
   284	            }
   285	        } finally { c.disconnect() }
   286	    }
   287	
   288	    private fun showOverlay() {
   289	        if (overlay != null || !Settings.canDrawOverlays(this)) return
   290	        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
   291	        val text = TextView(this).apply {
   292	            setTextColor(Color.WHITE)
   293	            setBackgroundColor(0xDD15171C.toInt())
   294	            textSize = 13f
   295	            setPadding(24, 18, 24, 14)
   296	            text = latestDisplay
   297	        }
   298	        statusText = text
   299	        val capture = TextView(this).apply {
   300	            textSize = 13f
   301	            gravity = Gravity.CENTER
   302	            setPadding(24, 14, 24, 16)
   303	            setOnClickListener { toggleCaptureDesired() }
   304	        }
   305	        captureButton = capture
   306	        val box = LinearLayout(this).apply {
   307	            orientation = LinearLayout.VERTICAL
   308	            addView(text)
   309	            addView(capture, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
   310	            elevation = 12f
   311	        }
   312	        val p = WindowManager.LayoutParams(
   313	            WindowManager.LayoutParams.WRAP_CONTENT,
   314	            WindowManager.LayoutParams.WRAP_CONTENT,
   315	            if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
   316	            else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE,
   317	            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
   318	            PixelFormat.TRANSLUCENT
   319	        ).apply { gravity = Gravity.TOP or Gravity.END; x = 24; y = 180 }
   320	        var dx0 = 0f; var dy0 = 0f; var ox = 0; var oy = 0; var moved = false
   321	        text.setOnTouchListener { _, e ->
   322	            when (e.actionMasked) {
   323	                MotionEvent.ACTION_DOWN -> { dx0=e.rawX; dy0=e.rawY; ox=p.x; oy=p.y; moved=false; true }
   324	                MotionEvent.ACTION_MOVE -> {
   325	                    val dx=e.rawX-dx0; val dy=e.rawY-dy0
   326	                    if (kotlin.math.abs(dx)+kotlin.math.abs(dy)>12) moved=true
   327	                    p.x=ox-dx.toInt(); p.y=oy+dy.toInt()
   328	                    runCatching { windowManager?.updateViewLayout(box,p) }
   329	                    true
   330	                }
   331	                MotionEvent.ACTION_UP -> { if (!moved) openAgora(); true }
   332	                else -> false
   333	            }
   334	        }
   335	        runCatching { windowManager?.addView(box, p); overlay=box; refreshCaptureUi() }
   336	    }
   337	
   338	    private fun refreshCaptureUi() {
   339	        scope.launch(Dispatchers.Main) {
   340	            val desired = prefs.getBoolean(KEY_CAPTURE_DESIRED, false)
   341	            captureButton?.apply {
   342	                when {
   343	                    desired && soConnected && captureEnabledForConnection -> {
   344	                        text = "● 通信观测中 · 点击停止"
   345	                        setTextColor(Color.WHITE)
   346	                        setBackgroundColor(0xDDAD2020.toInt())
   347	                    }
   348	                    desired -> {
   349	                        text = "◌ 已准备 · 等待 SO 后自动开启"
   350	                        setTextColor(Color.WHITE)
   351	                        setBackgroundColor(0xDD8A6500.toInt())
   352	                    }
   353	                    !soConnected -> {
   354	                        text = "○ 通信观测关闭 · 点击准备"
   355	                        setTextColor(0xFFCCCCCC.toInt())
   356	                        setBackgroundColor(0xDD303238.toInt())
   357	                    }
   358	                    else -> {
   359	                        text = "◎ 开始通信观测"
   360	                        setTextColor(Color.WHITE)
   361	                        setBackgroundColor(0xDD075FB8.toInt())
   362	                    }
   363	                }
   364	            }
   365	        }
   366	    }
   367	
   368	    private fun openAgora() = startActivity(Intent(this, MainActivity::class.java).apply {
   369	        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP) })
   370	
   371	    private fun notificationLabel(): String {
   372	        val capture = when {
   373	            prefs.getBoolean(KEY_CAPTURE_DESIRED, false) && captureEnabledForConnection -> " · 通信观测中"
   374	            prefs.getBoolean(KEY_CAPTURE_DESIRED, false) -> " · 通信待连接"
   375	            else -> ""
   376	        }
   377	        return "SO 已连接 · 自动${if (prefs.getBoolean(KEY_AUTO, false)) "开" else "关"}$capture"
   378	    }
   379	
   380	    private fun updateStatus(text: String, note: String) {
   381	        scope.launch(Dispatchers.Main) { statusText?.text=text }
   382	        getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification(note))
   383	    }
   384	
   385	    private fun servicePending(action: String, request: Int) = PendingIntent.getService(
   386	        this, request, Intent(this, UmaWorkbenchService::class.java).setAction(action),
   387	        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
   388	
   389	    private fun notification(text: String) = NotificationCompat.Builder(this, CHANNEL)
   390	        .setSmallIcon(R.drawable.ic_notification)
   391	        .setContentTitle("Agora · 赛马娘工作台")
   392	        .setContentText(text)
   393	        .setOngoing(true).setOnlyAlertOnce(true).setPriority(NotificationCompat.PRIORITY_LOW)
   394	        .setContentIntent(PendingIntent.getActivity(this, NOTIFICATION, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
   395	        .addAction(0, "分析", servicePending(ACTION_ANALYZE, 1))
   396	        .addAction(0, "通信开关", servicePending(ACTION_TOGGLE_CAPTURE, 2))
   397	        .addAction(0, "停止", servicePending(ACTION_STOP, 3)).build()
   398	
   399	    private fun createChannel() {
   400	        if (Build.VERSION.SDK_INT >= 26) getSystemService(NotificationManager::class.java)
   401	            .createNotificationChannel(NotificationChannel(CHANNEL,"Uma Workbench",NotificationManager.IMPORTANCE_LOW))
   402	    }
   403	
   404	    override fun onDestroy() {
   405	        monitorJob?.cancel()
   406	        overlay?.let { runCatching { windowManager?.removeView(it) } }
   407	        scope.cancel()
   408	        super.onDestroy()
   409	    }
   410	
   411	    override fun onBind(intent: Intent?): IBinder? = null
   412	}
413	
