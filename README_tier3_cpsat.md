# Tier 3 CP-SAT 求解器说明

## 1. 文件用途

`tier3_cpsat.py` 是机场地勤调度问题的 Tier 3 求解器，使用原生
Google OR-Tools CP-SAT 实现。

它以一个已有的 Tier 1/Tier 2 可行解作为初始解，并保持该解的登机口
分配不变，重新优化任务开始时间和 LaborID 分配，使结果进一步满足：

- C11：同一 LaborID 连续执行两个任务时，必须留出登机口之间的旅行时间；
- C12：连续工作跨度不能超过 90 分钟；有效空闲时间达到 15 分钟后，
  连续工作计时重置。

优化目标是最小化所有被使用 LaborID 的总成本。

## 2. 环境要求

- Python 3.10 或更高版本；
- Google OR-Tools；
- 不依赖 MiniZinc 运行时。

安装 OR-Tools：

```bash
python -m pip install ortools
```

## 3. 输入与输出

### 输入一：实例 JSON

比赛提供的实例文件，例如：

```text
data/hackathon_04.json
```

其中包含航班、任务、登机口、LaborID、班次、成本和旅行时间矩阵。

### 输入二：初始解 JSON

一个至少满足 C1–C10 的已有解，例如 Tier 2 输出：

```text
output/tier2_optimized/sol_04.json
```

求解器读取其中的：

- `gate`：作为固定登机口方案；
- `task_start`：作为 CP-SAT 搜索提示；
- `task_labor`：作为 LaborID 搜索提示。

初始解不要求满足 C11–C12。

### 输出

输出为比赛要求的 JSON：

```json
{
  "gate": ["..."],
  "task_start": [[0]],
  "task_labor": [["..."]],
  "cost": 0
}
```

其中 `cost` 是输出方案实际使用的不同 LaborID 的成本总和。

## 4. 运行方法

基本命令：

```bash
python tier3_cpsat.py INSTANCE_JSON INITIAL_SOLUTION OUTPUT_JSON
```

执行成本优化：

```bash
python tier3_cpsat.py \
  data/hackathon_04.json \
  output/tier2_optimized/sol_04.json \
  output/sol_04_tier3.json \
  --seconds 240 \
  --workers 8 \
  --optimize
```

PowerShell 写法：

```powershell
python tier3_cpsat.py `
  data\hackathon_04.json `
  output\tier2_optimized\sol_04.json `
  output\sol_04_tier3.json `
  --seconds 240 `
  --workers 8 `
  --optimize
```

参数说明：

| 参数 | 含义 |
|---|---|
| `INSTANCE_JSON` | 比赛实例 JSON |
| `INITIAL_SOLUTION` | 已有的 Tier 1/Tier 2/Tier 3 解 |
| `OUTPUT_JSON` | 新解的保存位置 |
| `--seconds` | 最大搜索时间，单位为秒 |
| `--workers` | CP-SAT 并行搜索线程数 |
| `--optimize` | 最小化 LaborID 总成本；不加时仅搜索可行解 |

建议先不加 `--optimize` 获得 Tier 3 可行解，再以该解作为初始解运行
带 `--optimize` 的命令。

## 5. 模型结构

### 5.1 任务变量

每个真实任务建立：

- `start[i]`：开始时间；
- `end[i]`：结束时间；
- `labor[i]`：执行任务的 LaborID；
- `assigned[i,l]`：任务是否分配给 LaborID `l`。

模型同时约束任务必须位于航班时间窗和人员班次内，并满足航班内部的
任务优先关系。

### 5.2 直接后继弧

对可能连续执行的同类型任务建立布尔变量：

```text
arc[i,j] = 1
```

其含义是：完成任务 `i` 的 LaborID 下一项直接执行任务 `j`。

弧被选中时强制：

```text
labor[i] = labor[j]
start[j] >= end[i] + travel[gate[i], gate[j]]
```

每个任务必须满足：

- 恰好有一个直接前驱，或者它是某条人员路径的首任务；
- 最多有一个直接后继；
- 每个被使用的 LaborID 恰好对应一条任务路径。

由于任务持续时间为正，选中的弧不可能形成时间循环。

### 5.3 C11：旅行时间

C11 只需要施加在同一人员路径的直接相邻任务上。若 `arc[i,j] = 1`：

```text
start[j] - end[i] >= travel[gate[i], gate[j]]
```

登机口来自初始解并在本模型中保持固定，因此旅行时间是常数。

### 5.4 C12：休息与连续工作

对每条直接后继弧建立 `rest[i,j]`：

```text
effective_idle = start[j] - end[i] - travel[gate[i], gate[j]]
```

- `effective_idle >= 15` 时，`rest[i,j] = 1`，连续工作起点重置为
  `start[j]`；
- `effective_idle <= 14` 时，连续工作起点从任务 `i` 传播到任务 `j`；
- 每个任务均约束 `start[i] - streak_start[i] <= 90`。

因此旅行时间不会被错误计算为休息时间。

### 5.5 成本目标

为每个 LaborID 建立 `used[l]`：

```text
used[l] = max(assigned[i,l])
```

优化目标为：

```text
minimize sum(labor_cost[l] * used[l])
```

## 6. 弧过滤

为避免给所有任务对建立变量，程序只保留满足以下条件的候选弧：

- 两个任务需要相同的团队类型；
- 两任务至少有一个共同候选 LaborID；
- 根据任务最早、最晚时间和旅行时间判断，该执行顺序仍可能成立。

这些过滤不会删除任何时间上可行的弧。

## 7. 验证输出

建议每个结果都运行两套独立验证器：

```bash
python validate_tier2.py data/hackathon_04.json output/sol_04_tier3.json
python validate_tier3.py data/hackathon_04.json output/sol_04_tier3.json
```

期望输出类似：

```text
VALID cost=9738 used_teams=39
VALID C11-C12 labor_timelines=39
```

第一条表示 C1–C10 通过，第二条表示 C11–C12 通过。

## 8. 当前结果

使用该方法获得并验证的 Tier 3 成本如下：

| 实例 | 成本 |
|---|---:|
| 01 | 2522 |
| 02 | 4491 |
| 03 | 8723 |
| 04 | 9738 |
| 05 | 14832 |
| 06 | 22249 |
| 07 | 18720 |

正式结果位于：

```text
output/tier3_native_optimized/
```

## 9. 大实例限制

如果某团队类型包含 `n` 个任务，直接后继弧最坏可能达到
`O(n^2)`。因此该整体模型适合 01–07，但在 08–12 上可能消耗大量
内存和搜索时间。

大实例建议使用：

1. 按团队类型分解；
2. 稀疏候选弧和自适应扩弧；
3. Routing 或最小费用流生成路径初始解；
4. 固定大部分已有弧，只释放局部任务的 LNS；
5. 外层调整 Gate，内层求人员路径和任务时间。

相关实验代码包括 `tier3_type_cpsat.py`、`tier3_routing_seed.py`、
`tier3_fixed_paths.py` 和 `tier3_gate_lns.py`，但这些不是复现 01–07
最佳结果所必需的文件。

