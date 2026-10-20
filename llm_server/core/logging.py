"""结构化日志（S-15）。

一行一条，前缀固定为 ``llmserver.<模块>``：
``llmserver.task`` / ``llmserver.chat`` / ``llmserver.prompt`` /
``llmserver.backend`` / ``llmserver.config``。

``--verbose``（或 ``config.server.verbose: true``）打开后额外打印完整
prompt 与 response 原文，便于排查「模型为什么输出了这个形状」。
"""

from __future__ import annotations

import logging
import os
import sys
from typing import Any

_PREFIX = 'llmserver'

#: 是否打印完整 prompt / response。由 run.py 或 config 设置。
VERBOSE: bool = False

_FORMAT = '%(asctime)s %(levelname)-7s %(name)s | %(message)s'
_DATEFMT = '%H:%M:%S'


def setup(level: str = 'info', verbose: bool = False) -> None:
    """配置根 logger（幂等）。"""
    global VERBOSE
    VERBOSE = verbose
    root = logging.getLogger()
    # 避免重复 addHandler 造成日志翻倍。
    for h in list(root.handlers):
        root.removeHandler(h)
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter(_FORMAT, datefmt=_DATEFMT))
    root.addHandler(handler)
    root.setLevel(_level_of(level))


def _level_of(level: str) -> int:
    return {
        'debug': logging.DEBUG,
        'info': logging.INFO,
        'warning': logging.WARNING,
        'error': logging.ERROR,
    }.get((level or 'info').lower(), logging.INFO)


def get_logger(module: str) -> logging.Logger:
    """取 ``llmserver.<module>`` 的 logger。"""
    return logging.getLogger(f'{_PREFIX}.{module}')


def is_verbose() -> bool:
    """当前是否处于 verbose 模式（环境变量 ``LLM_SERVER_VERBOSE=1`` 也可打开）。"""
    return VERBOSE or os.environ.get('LLM_SERVER_VERBOSE', '') in ('1', 'true', 'True')


def dump(logger: logging.Logger, title: str, payload: Any) -> None:
    """verbose 模式下打印完整 payload；否则只打印长度摘要。"""
    if isinstance(payload, str):
        text = payload
    else:
        text = repr(payload)
    if is_verbose():
        logger.info('---- %s (%d 字符) ----\n%s\n---- end %s ----', title, len(text), text, title)
    else:
        logger.debug('%s：%d 字符（开 --verbose 看全文）', title, len(text))
