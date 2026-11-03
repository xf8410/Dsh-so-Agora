# 06:43:34 · 附件1 of 1 — ObserveState.kt 原文

（来源：Transfer Dock_Text_20261104063933.txt）

1	package com.hualuo.engine.observe
     2	
     3	/**
     4	 * SO 观测桥连接状态机（560 清单 364-370 六态 + 373-379 超时/单并发/退避/熔断/冷却）。
     5	 *
     6	 * 纯 JVM、无 Android 依赖、无时钟隐藏——时间一律从外面喂（[nowMs]），
     7	 * 测试可以拨表。线程安全：所有可变状态锁在同一把上（状态机是唯一的写入口，
     8	 * 工具执行与探测都先问它要许可）。
     9	 *
    10	 * 单并发（375）：对端是嵌入式 SO，一人一格；[tryBegin] 抢不到就 false。
    11	 * 退避冷却（377/379）：连续失败翻倍退避，上限 5 分钟；OVERLOADED 从 60s 起。
    12	 * 熔断（378）：冷却期内工具直接拒——不是报错升级，是"现在别敲"的礼貌。
    13	 */
    14	class ObserveState(private val nowMs: () -> Long = { System.currentTimeMillis() }) {
    15	
    16	    enum class Link {
    17	        DISCONNECTED, CONNECTING, READY, DEGRADED, OVERLOADED, INCOMPATIBLE;
    18	
    19	        /** 中文显示名（UI 直接用）。 */
    20	        val label: String
    21	            get() = when (this) {
    22	                DISCONNECTED -> "未连接"
    23	                CONNECTING -> "探测中"
    24	                READY -> "已就绪"
    25	                DEGRADED -> "降级"
    26	                OVERLOADED -> "对端过载"
    27	                INCOMPATIBLE -> "疑似非 hlpatch"
    28	            }
    29	    }
    30	
    31	    @Volatile private var current: Link = Link.DISCONNECTED
    32	    private var busy = false
    33	    private var failureStreak = 0
    34	    private var cooldownUntil = 0L
    35	    /** 最后一次探测/调用的说明（人话账）。 */
    36	    @Volatile var lastNote: String = ""
    37	        private set
    38	
    39	    val link: Link get() = current
    40	
    41	    /** 冷却剩余毫秒；0 = 没在冷却。 */
    42	    fun cooldownRemainingMs(): Long = (cooldownUntil - nowMs()).coerceAtLeast(0L)
    43	
    44	    /**
    45	     * 探测前的许可：不在冷却且没人在探测，才发 [Link.CONNECTING]。
    46	     * 返回 false 时 [reasonRef]（可空）带上拒绝原因。
    47	     */
    48	    @Synchronized
    49	    fun tryBeginProbe(): Boolean {
    50	        if (busy) {
    51	            lastNote = "已有一次探测/请求在进行"
    52	            return false
    53	        }
    54	        val remain = cooldownRemainingMs()
    55	        if (remain > 0) {
    56	            lastNote = "冷却中，还剩 ${remain / 1000}s（连败 $failureStreak 次后的退避）"
    57	            return false
    58	        }
    59	        busy = true
    60	        current = Link.CONNECTING
    61	        return true
    62	    }
    63	
    64	    /**
    65	     * 用探测事实账收场（判定规则见 [ObserveClient.probe] 注）。
    66	     * 必须与 [tryBeginProbe] 成对调用（无论结果如何都要 [endBusy]）。
    67	     */
    68	    @Synchronized
    69	    fun settleProbe(healthOk: Boolean, statusOk: Boolean, healthStatus: Int?, note: String) {
    70	        endBusy()
    71	        when {
    72	            healthStatus == 503 || healthStatus == 429 -> {
    73	                current = Link.OVERLOADED
    74	                penalize(baseMs = 60_000)
    75	                lastNote = "对端忙（HTTP $healthStatus），进冷却退避"
    76	            }
    77	            !healthOk -> {
    78	                current = Link.DISCONNECTED
    79	                penalize()
    80	                lastNote = note
    81	            }
    82	            statusOk -> {
    83	                current = Link.READY
    84	                clearStreak()
    85	                lastNote = "探测通过：health + status 都通"
    86	            }
    87	            else -> {
    88	                current = Link.DEGRADED
    89	                clearStreak()
    90	                lastNote = note
    91	            }
    92	        }
    93	    }
    94	
    95	    /** 单次工具调用的许可：READY/DEGRADED 才放行（冷却/忙都拒）。 */
    96	    @Synchronized
    97	    fun tryBeginCall(): Boolean {
    98	        if (busy) {
    99	            lastNote = "已有一次探测/请求在进行（单并发）"
   100	            return false
   101	        }
   102	        val remain = cooldownRemainingMs()
   103	        if (remain > 0) {
   104	            lastNote = "冷却中，还剩 ${remain / 1000}s"
   105	            return false
   106	        }
   107	        if (current == Link.DISCONNECTED || current == Link.OVERLOADED || current == Link.INCOMPATIBLE) {
   108	            lastNote = "桥不在可调用态（$current），先探测"
   109	            return false
   110	        }
   111	        busy = true
   112	        return true
   113	    }
   114	
   115	    /** 工具调用收场：2xx 算顺，失败也只记一笔（不打断 READY——偶发失败别把桥判死）。 */
   116	    @Synchronized
   117	    fun settleCall(ok: Boolean, note: String) {
   118	        endBusy()
   119	        lastNote = note
   120	        if (!ok) failureStreak++
   121	    }
   122	
   123	    @Synchronized
   124	    fun endBusy() {
   125	        busy = false
   126	    }
   127	
   128	    /** 连败翻倍退避：5s 起步，翻倍，封顶 5 分钟。 */
   129	    private fun penalize(baseMs: Long = 0) {
   130	        failureStreak++
   131	        val backoff = if (baseMs > 0) baseMs else 5_000L shl (failureStreak - 1).coerceAtMost(9)
   132	        cooldownUntil = nowMs() + backoff.coerceAtMost(300_000L)
   133	    }
   134	
   135	    private fun clearStreak() {
   136	        failureStreak = 0
   137	        cooldownUntil = 0L
   138	    }
   139	}
   140	
