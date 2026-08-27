<!-- 默认仍优化成本，测试大数据时可快速生成有效解。 -->

<!-- 静态剪枝、冲突过滤、对称消除 -->

预计算兼容机位/团队
过滤无冲突任务对
消除同类团队对称
添加时间→团队→机位搜索顺序

增加任务必占区间的最低团队数下界
增加同能力团队的成本支配约束
撤回实测变慢的全局约束及 used-first 搜索

[airport_sched.mzn](D:/desktop/test/airport_sched.mzn)：增加必占区间下界、廉价团队优先的成本支配约束。
[solve_portfolio.ps1](D:/desktop/test/solve_portfolio.ps1)：并行运行 Chuffed、Gecode、CP-SAT，保存最低有效成本；全部失败时保留原文件。

调整搜索顺序

