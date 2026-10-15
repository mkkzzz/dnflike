# 项目协作入口

开工前按顺序读取：

1. `AGENTS.md` — 红线与协作流程
2. `docs/project/00_协作总纲.md` — 同步节点、冲突与提交规范
3. `docs/project/01_进度看板.md` — 当前进度
4. `docs/project/02_待办.md` — 阻塞与等待项

关键约定：

- 单分支 `main` 协作：提交前先 `git fetch`，落后则 `git pull --rebase`；禁止 force push
- 有产出即提交推送，并更新进度看板与交接日志
- 不覆盖他人改动，不静默重写文档
- 文档改动后运行 `python tools/check_docs.py`
