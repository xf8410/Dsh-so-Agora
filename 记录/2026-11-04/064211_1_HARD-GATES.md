# 06:42:11 · 附件1 of 4 — HARD-GATES.md 原文

（来源：Transfer Dock_Text_20261104063731.txt）

1	# 硬守门（HARD GATES）
     2	
     3	> **铁律**：本文件列出的每一条都是 CI 强制守门。**任何人不许改 CI/workflow 来绕过这些红线——包括 AI。**
     4	> 这条规矩本身（"硬守门不许改"）由 CODEOWNERS 锁死，只有 owner（花落）能批准修改。
     5	
     6	## 总原则
     7	
     8	1. **红了就是红了**——不跳过、不吞、不伪装、不截断
     9	2. **每个 PR 一个 feature**——不允许"一次性塞多个不相关功能"
    10	3. **每个 release 一个 tag**——不允许一个 tag 含多个 feature 产物
    11	4. **每个 artifact 必须可独立审计**——不带 zip-of-zip、不带隐式依赖
    12	5. **每个 commit message 必须能复述"做了什么"**——禁止"修一些 bug"这种含糊话
    13	
    14	---
    15	
    16	## 红线一 · 禁止构建时改源码（已存在）
    17	
    18	> CI 不许用 `sed -i` / `python3` / `gh api contents/git/refs` 等手段偷偷改源码然后编译。
    19	> 唯一例外：签名密钥首铸（commit 中带"密钥首铸"标记），且只写 `signing/` 两个文件。
    20	
    21	**检查位置**：`.github/workflows/ci.yml` 第 112-124 行
    22	
    23	---
    24	
    25	## 红线二 · 禁止把整个文件读进内存（已存在）
    26	
    27	> 正式代码不许出现 `readAllBytes()` / `readBytes()` / `toByteArray()`——大文件闪退的根因。
    28	> 统一走 `com.hualuo.engine.io.streamingCopy`，每次搬 64 KiB。
    29	
    30	**检查位置**：`.github/workflows/ci.yml` 第 126-137 行
    31	
    32	---
    33	
    34	## 红线三 · 单文件不许超过 999 行（已存在）
    35	
    36	> 单 .kt/.kts 文件超过 999 行必须拆开。巨型文件是补丁摞补丁的屎山信号。
    37	
    38	**检查位置**：`.github/workflows/ci.yml` 第 139-164 行
    39	
    40	---
    41	
    42	## 红线四 · 版本号只能有一个来源（已存在）
    43	
    44	> `version.properties` 是唯一版本号来源。`app/build.gradle.kts` / `engine/build.gradle.kts` / 源码里不许再写版本号。
    45	
    46	**检查位置**：`.github/workflows/ci.yml` 第 166-191 行
    47	
    48	---
    49	
    50	## 🆕 红线五 · 禁止假绿机制（核心防御）
    51	
    52	> **本红线直接挡"外绿内红"**——CI run 整体显示绿勾，但内部某步其实失败了。
    53	
    54	### 禁止 1：`continue-on-error: true`（除非显式批准）
    55	
    56	```yaml
    57	# ❌ 红——失败被吞
    58	- name: compile
    59	  continue-on-error: true
    60	  run: make build
    61	
    62	# ✅ 绿——失败就红
    63	- name: compile
    64	  run: make build
    65	```
    66	
    67	**唯一允许**：`actions/upload-artifact@v4` 的失败（网络/配额问题）可以用 `continue-on-error`，但必须在同一个 step 的 `if: always()` 块里打印配额状态。
    68	
    69	**历史教训**：
    70	- 旧 Agora 的 `build-workbench.yml` 三步全开此开关，结果"红被伪装成 skipped"，真正的编译错误又被 `tail -n 200` 截断
    71	- 旧 Agora 的 `bash -e` 把失败轮里的日志查看命令全变成死代码，想查都查不了
    72	
    73	### 禁止 2：禁止 `tail -n N` / `head -n N` 截断日志
    74	
    75	```bash
    76	# ❌ 红——错误行被截掉
    77	make build 2>&1 | tail -n 200
    78	
    79	# ✅ 绿——全量保留
    80	make build 2>&1 | tee build.log
    81	# 失败时再读全量日志
    82	```
    83	
    84	**历史教训**：Agora 的 CI 把所有日志 `tail -n 200`，导致编译错误在 tail 之后——run 看起来绿，错误其实在那里。
    85	
    86	### 禁止 3：禁止 `|| true` 吞错误
    87	
    88	```bash
    89	# ❌ 红——失败被吞
    90	make build || true
    91	
    92	# ❌ 红——bash 三段式错误吞
    93	cmd1 && cmd2 || echo "fallback"
    94	```
    95	
    96	**正确做法**：`set -euo pipefail` 强制每一步失败就退出。
    97	
    98	### 禁止 4：禁止 `set +e` / `set +o pipefail` 关错误检查
    99	
   100	```bash
   101	# ❌ 红——禁用错误检查
   102	set +e
   103	make build
   104	```
   105	
   106	**正确做法**：`set -euo pipefail` 在每个 step 第一行。
   107	
   108	### 禁止 5：禁止 `if: always()` 隐藏关键 step 失败
   109	
   110	```yaml
   111	# ❌ 红——上传日志这一步无论成败都跑，但语义上"日志"在 build 失败时反而隐藏错误
   112	- name: 收日志
   113	  if: always()
   114	  uses: actions/upload-artifact@v4
   115	  with:
   116	    name: log
   117	    path: logs/
   118	
   119	# ✅ 绿——失败时单独跑失败摘要
   120	- name: 收日志
   121	  if: always()
   122	  uses: actions/upload-artifact@v4
   123	  with:
   124	    name: log
   125	    path: logs/
   126	- name: 失败摘要
   127	  if: failure()
   128	  run: cat logs/* | head -200
   129	```
   130	
   131	**关键**：`if: always()` 可以用于"无论成败都收日志"——这是合理的；但**禁止把它当"吞错工具"**——必须在 `if: failure()` 块里把错误显式暴露出来。
   132	
   133	### 检查脚本
   134	
   135	`.github/scripts/check-no-fake-green.sh` 自动跑上述 5 项检查。
   136	**触发位置**：CI 的 "红线五·禁止假绿机制" step。
   137	
   138	---
   139	
   140	## 🆕 红线六 · PR 必须单功能
   141	
   142	> **每个 PR 只允许改一个 module**——不允许"一次性塞多个不相关功能"。
   143	
   144	### 强制 1：PR title 必须是 Conventional Commits 格式
   145	
   146	```
   147	feat(<scope>): <什么新功能>
   148	fix(<scope>): <修了什么>
   149	refactor(<scope>): <重构了什么>
   150	perf(<scope>): <性能优化>
   151	test(<scope>): <测试相关>
   152	docs(<scope>): <文档>
   153	ci(<scope>): <CI 改动>
   154	chore(<scope>): <杂项>
   155	```
   156	
   157	**scope 必须**是以下之一：`engine` / `app` / `docs` / `ci` / `signing` / `release` / `scripts`。
   158	
   159	### 强制 2：PR 改动的文件必须属于一个 module
   160	
   161	```
   162	engine/  →  engine
   163	app/     →  app
   164	docs/    →  docs
   165	.github/ + scripts/  →  ci
   166	signing/  →  signing
   167	releases/  →  release
   168	```
   169	
   170	**规则**：
   171	- PR 不能同时改 `engine/ + app/`——除非是跨 module 的接口调整，且 commit message 显式标注
   172	- PR 不能同时改 `engine/ + ci/`——"功能改动"和"CI 改动"必须分开
   173	- 一个 PR 一个 feature——不允许"feat A + refactor B + 修个 typo"三合一
   174	
   175	### 检查脚本
   176	
   177	`.github/scripts/check-pr-single-feature.sh` 自动跑。
   178	**触发位置**：CI 的 "红线六·PR 必须单功能" step（PR trigger）。
   179	
   180	---
   181	
   182	## 🆕 红线七 · artifact 不嵌 zip
   183	
   184	> **CI 产出的 zip 里不许再套 zip**——用户抱怨"16.5 MB 的自检日志里塞了一堆 zip"。
   185	
   186	### 强制 1：release asset 禁止 zip-of-zip
   187	
   188	```bash
   189	# ❌ 红——release 里塞 zip 包
   190	Hualuo-v3.0.zip
   191	├── Hualuo-v3.0.so
   192	└── Hualuo-v3.0-extra.zip  # ← 这层不允许
   193	
   194	# ✅ 绿——扁平结构
   195	Hualuo-v3.0.zip
   196	├── Hualuo-v3.0.so
   197	├── self-check.log
   198	├── MANIFEST.txt
   199	└── Hualuo-v3.0.so.sha256
   200	```
   201	
   202	### 强制 2：CI artifact zip 不超过 5 MB（除非是 build 产物）
   203	
   204	| Artifact 类型 | 大小上限 |
   205	|---|---|
   206	| 自检日志 | 5 MB |
   207	| 单元测试 XML | 2 MB |
   208	| 编译产物（apk/aar/so） | 不限 |
   209	| 文档 | 5 MB |
   210	| 其他 | 1 MB |
   211	
   212	**超额自动红**——避免像 #301 那样把 870 MB 塞进 artifact 撑爆配额。
   213	
   214	### 强制 3：每个 artifact 必须含 `self-check.log`（自检日志）
   215	
   216	**self-check.log 必备字段**：
   217	
   218	```
   219	== self-check ==
   220	tag=<release tag>
   221	commit_sha=<full sha>
   222	timestamp=<ISO 8601 UTC>
   223	version=<versionName>
   224	build_target=<debug|release>
   225	test_engine=<PASS|FAIL count=...>
   226	test_app=<PASS|FAIL count=...>
   227	clippy=<PASS|FAIL warnings=...>
   228	red_lines=<PASS|FAIL which=...>
   229	artifact_size_total=<bytes>
   230	apk_debug=<path> sha256=<sha>
   231	apk_release=<path> sha256=<sha>
   232	== /self-check ==
   233	```
   234	
   235	### 检查脚本
   236	
   237	`.github/scripts/check-artifact-no-zip-in-zip.sh` 自动跑。
   238	**触发位置**：CI 的 "红线七·artifact 不嵌 zip" step。
   239	
   240	---
   241	
   242	## 🆕 红线八 · 每 tag 单次 CI + 单 feature release
   243	
   244	> **每个 release tag 必须对应一次完整 CI + 单个 feature**。
   245	
   246	### 强制 1：release tag 格式
   247	
   248	```
   249	vX.Y.Z            # 主版本号
   250	vX.Y.Z-feature    # feature 版本（一个 tag 一个 feature）
   251	vX.Y.Z-fix        # 修复版本
   252	```
   253	
   254	### 强制 2：每个 tag 触发一次 CI（不串联）
   255	
   256	```yaml
   257	on:
   258	  push:
   259	    tags:
   260	      - 'v*'
   261	# 不允许 workflow_call / workflow_dispatch 串联多 tag
   262	```
   263	
   264	### 强制 3：release asset 单 feature
   265	
   266	每个 release tag 最多 3 个 asset：
   267	- `Hualuo-<version>.apk` —— 主产物
   268	- `self-check.log` —— 自检日志（必备）
   269	- `MANIFEST.txt` —— 变更清单（必备）
   270	
   271	**禁止**：
   272	- ❌ 一个 tag 塞多个 feature 的产物
   273	- ❌ 一个 tag 不带 self-check.log
   274	- ❌ 一个 tag 不带 MANIFEST.txt
   275	
   276	### 强制 4：tag 必须能在历史 commit 中找到对应 commit message
   277	
   278	```bash
   279	# ❌ 红——tag 但找不到对应 commit
   280	git tag --points-at HEAD  # 必须有一个 commit message 跟 tag 名匹配
   281	
   282	# ✅ 绿——tag v0.7.0-feat-streaming 对应 commit "feat(engine): ..."
   283	```
   284	
   285	### 检查脚本
   286	
   287	`.github/scripts/check-tag-single-feature.sh` 自动跑。
   288	**触发位置**：CI 的 "红线八·每 tag 单次 CI" step（tag trigger）。
   289	
   290	---
   291	
   292	## 守门纪律
   293	
   294	1. **红线改了要写原因**——任何对 HARD-GATES.md 的修改必须配 commit message 写清楚为什么改
   295	2. **改了红线必须过审计**——CODEOWNERS 强制 owner 审批
   296	3. **红线发现漏洞先堵 PR 再补文档**——不允许"先 commit 漏洞、再写文档说以后注意"
   297	4. **AI 不许绕过守门**——任何"AI 为了图方便调过红线"的尝试一律拒绝
298	
