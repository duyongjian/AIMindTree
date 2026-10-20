"""一行启动入口。

用法（仓库根目录）：

    python llm_server/run.py
    python llm_server/run.py --port 8788 --verbose
    python llm_server/run.py --config llm_server/config.yaml

Windows 双击：``scripts/run_llm_server.bat``。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# 让 `python llm_server/run.py` 直接可跑：把 llm_server/ 放进 sys.path，
# 这样 core/ backends/ routers/ 都能以顶层模块方式 import。
_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import uvicorn  # noqa: E402

from server import VERSION, create_app  # noqa: E402


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog='llm_server',
        description='AIMindTree 自研 LLM Server（FastAPI, 127.0.0.1:8787）',
    )
    parser.add_argument('--host', default=None, help='监听地址（默认取 config.yaml）')
    parser.add_argument('--port', type=int, default=None, help='监听端口（默认取 config.yaml）')
    parser.add_argument(
        '--config', default=None, help='config.yaml 路径（默认 llm_server/config.yaml）'
    )
    parser.add_argument(
        '--prompts', default=None, help='提示词目录（默认 llm_server/prompts）'
    )
    parser.add_argument(
        '--verbose',
        action='store_true',
        help='打印完整 prompt / response（排查模型输出形状用）',
    )
    parser.add_argument(
        '--log-level',
        default=None,
        choices=['debug', 'info', 'warning', 'error'],
        help='日志级别（默认取 config.yaml）',
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    app = create_app(config_path=args.config, prompts_dir=args.prompts)

    cfg_server = app.state.config.server
    host = args.host or str(cfg_server.get('host', '127.0.0.1'))
    port = int(args.port or cfg_server.get('port', 8787))
    verbose = bool(args.verbose or cfg_server.get('verbose', False))
    log_level = args.log_level or str(cfg_server.get('log_level', 'info'))

    app.state.config.server['host'] = host
    app.state.config.server['port'] = port
    app.state.config.server['verbose'] = verbose
    app.state.config.server['log_level'] = log_level

    print(f'AIMindTree LLM Server v{VERSION} → http://{host}:{port}')
    print(f'  默认后端：{app.state.config.default_backend}')
    print(f'  提示词：{app.state.store.dir}（已加载 {app.state.store.count()} 个）')
    print('  健康检查：GET /health    提示词列表：GET /v1/prompts')
    print('  Ctrl+C 退出')

    uvicorn.run(
        app,
        host=host,
        port=port,
        log_level='debug' if verbose else log_level,
        # Windows 上 reload 会额外起子进程、信号处理不稳（Q-K），一律关掉；
        # 热更新走 POST /v1/prompts/reload 与 POST /v1/admin/reload。
        reload=False,
        access_log=verbose,
    )
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
