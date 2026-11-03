# 06:42:11 · 附件4 of 4 — ObserveClient.kt 原文

（来源：Transfer Dock_Text_20261104063911.txt）

1	package com.hualuo.engine.observe
     2	
     3	import com.hualuo.engine.api.WireRequest
     4	import com.hualuo.engine.api.WireTransport
     5	import java.io.IOException
     6	import java.net.URLEncoder
     7	
     8	/**
     9	 * hlpatch SO 观测桥客户端（560 清单 361-400 域的第一块引擎件）。
    10	 *
    11	 * 对端是跑在设备本机的 hlpatch SO 插件（默认 127.0.0.1:18765），只读 HTTP：
    12	 * 全部 GET、返回 JSON 文本。客户端只做三件事：把路径管干净、把响应字节管干净、
    13	 * 把事实（状态码/耗时/字节数）报出来——**不改写、不截断内容、不脱敏**，原文照收。
    14	 *
    15	 * 端点全集（对齐旧仓 UmaToolProvider 的映射，逐条对过）：
    16	 *   /health /status /summary
    17	 *   /api/event/choices  /api/event/observations?after_id=N
    18	 *   /debug/hookdiag  /debug/event_reward_targets  /debug/ramen_transition
    19	 *   /classes/search/<kw>  /fields/<class>  /methods/<class>  /find_method/<method>
    20	 *
    21	 * 红线（560 清单 400）：**禁止普通流程默认全量类扫描**——所以本客户端不提供
    22	 * "list 全部类"的便捷方法；通用口 [get] 可以读任意路径，但只有用户/模型显式
    23	 * 点名某条路径才会走到（显式点名 = 用户决定，不归普通流程）。
    24	 */
    25	class ObserveClient(
    26	    /** 形如 http://127.0.0.1:18765，不带尾斜杠。 */
    27	    val baseUrl: String,
    28	    private val transport: WireTransport,
    29	) {
    30	
    31	    /** 一次 GET 的事实账：状态码 + 原文（2xx）或错误体（非 2xx）或异常说明。 */
    32	    data class GetOutcome(
    33	        val path: String,
    34	        val httpStatus: Int?,
    35	        /** 2xx 时是响应原文；非 2xx 时是错误体；连接失败时为 null。 */
    36	        val body: String?,
    37	        val error: String?,
    38	        val elapsedMs: Long,
    39	        val bytes: Long,
    40	        /** 失败类别：报错按类说人话（超限/连不上/HTTP 状态），别让上层猜字符串。 */
    41	        val kind: Kind = Kind.HTTP,
    42	    ) {
    43	        val ok: Boolean get() = httpStatus != null && httpStatus in 200..299 && body != null
    44	    }
    45	
    46	    /** GetOutcome 的类别。 */
    47	    enum class Kind { OK, HTTP, TOO_LARGE, IO }
    48	
    49	    /**
    50	     * 只读 GET 一条路径。
    51	     *
    52	     * 字节纪律（红线二）：响应经 transport 逐行交付，这里分块拼、超 [maxBytes]
    53	     * 立刻断——不把大响应一口气吞进内存；超限是异常，报账不硬撑。
    54	     * 超时按端点自适应：探活类短等，大摘要多等（对端是嵌入式 SO，忙起来慢）。
    55	     */
    56	    fun get(path: String, maxBytes: Int = DEFAULT_MAX_BYTES): GetOutcome {
    57	        val clean = validateReadPath(path)
    58	        val started = System.currentTimeMillis()
    59	        val request = WireRequest(
    60	            url = baseUrl + clean,
    61	            method = "GET",
    62	            connectTimeoutMs = CONNECT_TIMEOUT_MS,
    63	            readTimeoutMs = readTimeoutFor(clean),
    64	        )
    65	        val collected = StringBuilder()
    66	        var received = 0L
    67	        return try {
    68	            val response = transport.exchange(request) { line ->
    69	                val piece = line + "\n"
    70	                val pieceBytes = piece.toByteArray(Charsets.UTF_8).size.toLong()
    71	                if (received + pieceBytes > maxBytes) {
    72	                    throw ObserveTooLargeException(received, maxBytes.toLong())
    73	                }
    74	                collected.append(piece)
    75	                received += pieceBytes
    76	                true
    77	            }
    78	            GetOutcome(
    79	                path = clean,
    80	                httpStatus = response.status,
    81	                body = if (response.status in 200..299) collected.toString() else response.errorBody,
    82	                error = if (response.status in 200..299) null else "HTTP ${response.status}",
    83	                kind = if (response.status in 200..299) Kind.OK else Kind.HTTP,
    84	                elapsedMs = System.currentTimeMillis() - started,
    85	                bytes = received,
    86	            )
    87	        } catch (e: ObserveTooLargeException) {
    88	            GetOutcome(
    89	                path = clean,
    90	                httpStatus = null,
    91	                body = collected.toString(),
    92	                error = "响应超过 ${maxBytes / 1024} KiB 上限，已断（已收 ${e.bytesSoFar} 字节）",
    93	                kind = Kind.TOO_LARGE,
    94	                elapsedMs = System.currentTimeMillis() - started,
    95	                bytes = received,
    96	            )
    97	        } catch (e: IOException) {
    98	            GetOutcome(
    99	                path = clean,
   100	                httpStatus = null,
   101	                body = null,
   102	                error = e.message ?: "连接失败（18765 无响应或超时）",
   103	                kind = Kind.IO,
   104	                elapsedMs = System.currentTimeMillis() - started,
   105	                bytes = received,
   106	            )
   107	        }
   108	    }
   109	
   110	    /** 超限异常：带上断开前已收的字节数，报账用。 */
   111	    class ObserveTooLargeException(val bytesSoFar: Long, val limit: Long) :
   112	        IOException("observe 响应超过 $limit 字节上限")
   113	
   114	    /** 一次探测的收场：两端点的事实账。 */
   115	    data class ProbeOutcome(
   116	        val health: GetOutcome?,
   117	        val status: GetOutcome?,
   118	    )
   119	
   120	    /**
   121	     * 探测序列：先 GET /health（通且像 hlpatch）再 GET /status。
   122	     * 判定规则（[ObserveLink] 六态）在 [ObserveLink.probe] 落地，纯 JVM 可测：
   123	     *   health 不通：DISCONNECTED（18765 无响应/拒绝/超时）
   124	     *   health 503/429：OVERLOADED（对端忙，进冷却）
   125	     *   health 2xx 但空体：DEGRADED（有东西应答但说不出健康）
   126	     *   health 2xx 非 JSON：INCOMPATIBLE（疑似不是 hlpatch 在这个端口上）
   127	     *   health 通 status 败：DEGRADED（桥活着，状态端点不给力）
   128	     *   两个都通            到 READY
   129	     * 版本兼容性不硬判：/health 原文原样带回，人眼/模型自己看版本号。
   130	     */
   131	    fun probe(): ProbeOutcome {
   132	        val health = get(ENDPOINT_HEALTH, maxBytes = 64 * 1024)
   133	        if (!health.ok) return ProbeOutcome(health, null)
   134	        val body = health.body.orEmpty().trim()
   135	        if (body.isEmpty()) return ProbeOutcome(health, null)
   136	        if (!looksLikeJson(body)) return ProbeOutcome(health, null)
   137	        val status = get(ENDPOINT_STATUS, maxBytes = 256 * 1024)
   138	        return ProbeOutcome(health, status)
   139	    }
   140	
   141	    companion object {
   142	        const val ENDPOINT_HEALTH = "/health"
   143	        const val ENDPOINT_STATUS = "/status"
   144	        const val ENDPOINT_SUMMARY = "/summary"
   145	        const val ENDPOINT_EVENT_CHOICES = "/api/event/choices"
   146	        const val ENDPOINT_EVENT_OBSERVATIONS = "/api/event/observations"
   147	        const val ENDPOINT_HOOK_DIAG = "/debug/hookdiag"
   148	        const val ENDPOINT_EVENT_REWARD_TARGETS = "/debug/event_reward_targets"
   149	        const val ENDPOINT_RAMEN_TRANSITION = "/debug/ramen_transition"
   150	
   151	        // ---- 嗅探/协议观测（只读查询；toggle/clear/install 是写操作，不做工具） ----
   152	        const val ENDPOINT_SNIFF_STATUS = "/api/sniff/status"
   153	        const val ENDPOINT_SNIFF_METADATA = "/api/sniff/metadata"
   154	        const val ENDPOINT_SNIFF_UNITY = "/api/sniff/unity"
   155	        const val ENDPOINT_SNIFF_DIAG = "/api/sniff/diag"
   156	        const val ENDPOINT_MD5LOG = "/api/md5log"
   157	
   158	        // ---- 育成数据 ----
   159	        const val ENDPOINT_DATA = "/data"
   160	        const val ENDPOINT_SCENARIO = "/scenario"
   161	        const val ENDPOINT_EVENTS = "/events"
   162	        const val ENDPOINT_EVENT_RECOMMEND = "/event/recommend"
   163	        const val ENDPOINT_ACTION_LATEST = "/action/latest"
   164	        const val ENDPOINT_TRAINING_RESULT = "/training/result"
   165	        const val ENDPOINT_LOG = "/log"
   166	        const val ENDPOINT_LOG_TURN = "/log/turn"
   167	
   168	        // ---- 拉面（育成 AI 主线） ----
   169	        const val ENDPOINT_RAMEN = "/ramen"
   170	        const val ENDPOINT_RAMENINFO = "/debug/rameninfo"
   171	        const val ENDPOINT_RAMENGAINS = "/debug/ramengains"
   172	        const val ENDPOINT_RAMEN_PARTICIPANTS = "/debug/ramen_participants"
   173	        const val ENDPOINT_RAMEN_PLANNER_STATE = "/debug/ramen_planner_state"
   174	
   175	        // ---- 种子/继承/数据库 ----
   176	        const val ENDPOINT_SEED_HISTORY = "/seed/history"
   177	        const val ENDPOINT_SEED_STATS = "/seed/stats"
   178	        const val ENDPOINT_INHERIT_COMPAT = "/inherit/compat"
   179	        const val ENDPOINT_CARDDB = "/carddb"
   180	        const val ENDPOINT_SKILLDATA = "/skilldata"
   181	        const val ENDPOINT_MDB = "/mdb"
   182	        const val ENDPOINT_MDB_SCHEMA = "/mdb/schema"
   183	        const val ENDPOINT_MDB_SEARCH = "/mdb/search"
   184	        const val ENDPOINT_SINGLETONS = "/singletons"
   185	        const val ENDPOINT_TABLES = "/tables"
   186	
   187	        // ---- debug 高频 ----
   188	        const val ENDPOINT_GAUGE = "/debug/gauge"
   189	        const val ENDPOINT_GAUGE2 = "/debug/gauge2"
   190	        const val ENDPOINT_TRAINING_PARTNERS = "/debug/training_partners"
   191	        const val ENDPOINT_TRAINING_SEED = "/debug/training_seed"
   192	        const val ENDPOINT_TURN_PROBE = "/debug/turn_probe"
   193	        const val ENDPOINT_BREEDERS = "/debug/breeders"
   194	
   195	        /** 单次默认字节上限：16 MiB（旧仓同档；summary 会到 2 MiB 级）。 */
   196	        const val DEFAULT_MAX_BYTES = 16 * 1024 * 1024
   197	        const val CONNECT_TIMEOUT_MS = 5_000
   198	
   199	        /** 读路径校验（照旧仓 validateReadPath 逐条重写）：
   200	         *  / 开头、长度 2-1000、不许 // 开头、不许 ://（防绝对/网络 URL）、无控制字符。 */
   201	        fun validateReadPath(input: String): String {
   202	            require(input.startsWith('/')) { "path 必须以 / 开头" }
   203	            require(input.length in 2..1000) { "path 长度必须在 2-1000" }
   204	            require(!input.startsWith("//") && !input.contains("://")) { "path 不许是绝对/网络地址" }
   205	            require(input.none { it == '\r' || it == '\n' || it == '\u0000' }) { "path 含控制字符" }
   206	            return input
   207	        }
   208	
   209	        /** 路径段安全化：URL 编码（防 / 注入到别的端点），长度 1-500。 */
   210	        fun safeSegment(value: String, label: String): String {
   211	            require(value.length in 1..500) { "$label 长度必须 1-500" }
   212	            require(value.none { it == '\r' || it == '\n' || it == '\u0000' }) { "$label 含控制字符" }
   213	            return URLEncoder.encode(value, "UTF-8")
   214	        }
   215	
   216	        /** 读超时按端点分档：探活快、摘要慢（嵌入式 SO 忙起来生成摘要要等）。 */
   217	        fun readTimeoutFor(path: String): Int = when {
   218	            path == ENDPOINT_HEALTH || path == ENDPOINT_STATUS -> 10_000
   219	            // 大响应端点：摘要/完整协议观测/全调试数据，SO 生成要时间
   220	            path == ENDPOINT_SUMMARY || path == ENDPOINT_SNIFF_METADATA ||
   221	                path == ENDPOINT_MDB || path == ENDPOINT_CARDDB ||
   222	                path == ENDPOINT_SKILLDATA || path == ENDPOINT_DATA -> 60_000
   223	            else -> 30_000
   224	        }
   225	
   226	        /** 粗判 JSON：首字符 { 或 [。不引序列化器，纯字符判断（探测够用）。 */
   227	        fun looksLikeJson(text: String): Boolean {
   228	            val t = text.trim()
   229	            return t.startsWith("{") || t.startsWith("[")
   230	        }
   231	
   232	        /**
   233	         * 状态码的中文人话（用户纪律：报错不许甩裸 "HTTP 404"，要带名字）。
   234	         * 数字仍附在括号里当事实，解释在前、数字在后。
   235	         */
   236	        fun httpExplain(code: Int): String = when (code) {
   237	            400 -> "请求格式不对，对端拒收（400）"
   238	            401, 403 -> "对端拒绝访问（$code）"
   239	            404 -> "对端没这条路由（404）——hlpatch 版本不同端点会变，可用 uma_read_endpoint 显式试别的路径"
   240	            405 -> "对端不认这个请求方式（405）"
   241	            408 -> "对端等太久没回（408）"
   242	            429 -> "对端在忙，请求太密（429）"
   243	            in 500..599 -> "对端内部出错（$code）——游戏可能在忙或插件状态异常，稍后再试"
   244	            else -> "对端返回异常状态（$code）"
   245	        }
   246	    }
   247	}
   248	
