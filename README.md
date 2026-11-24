# User Skills

AI Agent 技能集合，遵循 [Agent Skills](https://agentskills.io/specification) 规范。

## 技能列表

### 提示词工程

| 技能 | 说明 |
|------|------|
| `z-prompt-fix-logic` | 提示词逻辑整理 |
| `z-prompt-fix-text` | 提示词语文表达、格式、层级修补 |
| `z-prompt-human` | 提示词人性化，按人类阅读逻辑重写且保持 AI 语义等效 |
| `z-prompt-fix-ai` | 提示词 AI 边界适配 |
| `z-prompt-fix-struct` | 提示词 13 维度结构审查 |
| `z-prompt-slim` | 语句瘦身 |
| `z-prompt-reboot` | 提示词颠覆性重构 |

### 认知与对话

| 技能 | 说明 |
|------|------|
| `z-need-clarify` | 需求澄清，挖掘真实意图与潜在痛点 |
| `z-mind-guide` | 认知导师，苏格拉底式提问引导深度思考 |
| `z-zen-awaken` | 大师点醒，极简箴言 |
| `z-leader-talk` | 格局领导谈话术 |
| `z-idea-grill` | 结构化拷问计划或决定 |
| `z-johari-ask` | 四象限沟通法（乔哈里窗） |

### 写作与文档

| 技能 | 说明 |
|------|------|
| `z-spec-wording` | 技术文档措辞校准，收敛到工程规范语域 |
| `z-minimal` | 对事情做减法：极简、干净，减到尽头即是本质 |

### 分析与诊断

| 技能 | 说明 |
|------|------|
| `z-expert-group` | 专家合议组，多专家深度研讨 |
| `z-fact-check` | 事实核查，识别幻觉与编造 |
| `z-root-fix` | 根因求解 |
| `z-meta-fix` | 元层根因透镜，先判定问题是否值得解答 |
| `z-debunk` | 刁钻反方专家，攻击性打假 |
| `z-theory-forge` | 理论锻造，建构—反驳—重构循环 |

### 任务执行

| 技能 | 说明 |
|------|------|
| `z-task-run` | 通用任务执行与目录管理 |
| `z-agent-arena` | 并行竞技场，多子代理竞演、对比后合成综合最优结果 |
| `z-backup` | 文件/目录备份，只增不减 |

## 使用

Windows 运行 `deploy-skills.bat`，将所有 `z-*` 技能部署到 Qoder、CodeBuddy、OpenCode、Trae、Pi、WorkBuddy 的 skills 目录（与 git 无关，不涉及 pull/push）。

脚本会在每个目标的 skills 目录下维护部署清单 `.deployed-skills.json`：只有清单内、且源中已不存在的 `z-*` 项才会被清理；目标目录中其他途径安装的技能（含 `z-*` 命名者）一律保留不动，无清单时不做任何清理。


调用方式：`/skill:z-need-clarify`，或在对话中直接说出技能名。
