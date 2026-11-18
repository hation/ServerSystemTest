"""HDM SDS 日志包 AI 综合分析模块（可选）。

提供两份能力供 T7 报告渲染与 CLI 使用：

- build_ai_payload(inv, health, events) -> str：把解析结果整理成
  「事实先行」文本块（机器信息 + 组件健康清单 + 事件时间线 + 分析任务
  指令）。同一份文本供双模式复用：默认落盘为 <basename>-ai-facts.md
  材料包供当前会话 AI 做综合总结；--ai 时作为 OpenAI 兼容 API 请求
  content。
- call_ai(payload, base_url=None, api_key=None, model=None) -> str | None：
  直连 OpenAI 兼容 `{base_url}/chat/completions`，取 message.content。
  参数缺省时回退环境变量 SDS_AI_BASE_URL / SDS_AI_API_KEY / SDS_AI_MODEL
  （model 缺省再回退 deepseek-v4-flash）；缺 base_url、网络异常、HTTP 非
  200、响应无 content 一律返回 None（不抛异常）。reasoning_content 字段
  忽略，不参与返回。

密钥安全：API Key 只经参数/环境变量进入内存，绝不写入任何文件、报告或
日志。运行时零第三方依赖，仅用 Python 3.12 标准库（urllib.request）。
"""

import json
import os
import urllib.request

# 分析任务指令（措辞逐字取自任务简报，T7 与验收用例以其为锚点）
_TASK_INSTRUCTIONS = '请基于以上事实输出：① 异常链路推断 ② 根因候选排序 ③ 可执行的排查步骤'

_DEFAULT_MODEL = 'deepseek-v4-flash'
_REQUEST_TIMEOUT = 60  # LLM 推理可能较慢，给足超时


def build_ai_payload(inv, health, events) -> str:
    """把解析结果整理为「事实 + 任务指令」文本块（中文，Markdown 风格纯文本）。

    事实先行：机器信息 → 组件健康清单（组件/状态/证据事件原文/建议）→
    事件时间线（sbe 来源标注"尽力而为"）；末尾附固定分析任务指令。
    同一份文本双模式复用（落盘材料包 / API 请求 content）。
    """
    lines = ['# HDM SDS 体检 AI 分析材料包', '']

    # 一、机器信息
    lines.append('## 机器信息')
    machine = (inv.machine or {}) if inv is not None else {}
    lines.append(f"- 产品型号: {machine.get('product_name') or '未知'}")
    lines.append(f"- 序列号: {machine.get('serial_number') or '未知'}")
    lines.append(f"- 产品部件号: {machine.get('product_part_number') or '未知'}")
    firmware = (inv.firmware or {}) if inv is not None else {}
    fw = ', '.join(f'{k}={v}' for k, v in firmware.items() if v) or '未知'
    lines.append(f'- 固件版本: {fw}')
    lines.append('')

    # 二、组件健康清单（组件/状态/证据事件原文/建议）
    lines.append('## 组件健康清单')
    comps = list(health or [])
    if not comps:
        lines.append('- （无组件健康判定数据）')
    for comp in comps:
        name = getattr(comp, 'name', None) or '未知'
        category = getattr(comp, 'category', None) or '未知'
        status = getattr(comp, 'status', None) or '未知'
        lines.append(f'- {name}（{category}）: 状态={status}')
        evidence = getattr(comp, 'evidence', None) or []
        if evidence:
            lines.append('  证据事件:')
            for ev in evidence:
                lines.append(f'    - {ev}')
        suggestions = getattr(comp, 'suggestions', None) or []
        if suggestions:
            lines.append('  修复建议:')
            for s in suggestions:
                lines.append(f'    - {s}')
    lines.append('')

    # 三、事件时间线（按时间排序，供"异常链路推断"按时间线串联参考）
    lines.append('## 事件时间线')
    evs = list(events or [])
    evs.sort(key=lambda e: (
        0 if (getattr(e, 'timestamp', None) or '') != '未知' else 1,
        getattr(e, 'timestamp', None) or '',
    ))
    if not evs:
        lines.append('- （无事件记录）')
    for ev in evs:
        ts = getattr(ev, 'timestamp', None) or '未知'
        sev = getattr(ev, 'severity', None) or ''
        sensor = getattr(ev, 'sensor_name', None) or ''
        desc = getattr(ev, 'desc', None) or ''
        source = getattr(ev, 'source', None) or ''
        marker = '（来自尽力而为的 .sbe 解析）' if source == 'sbe' else ''
        lines.append(f'- [{ts}] {sev} {sensor}: {desc}（来源: {source}）{marker}')
    lines.append('')

    # 四、分析任务指令（固定锚点，供会话 AI / 后端模型执行）
    lines.append('## 分析任务指令')
    lines.append(_TASK_INSTRUCTIONS)
    return '\n'.join(lines)


def _extract_content(data) -> str | None:
    """从 chat/completions 响应 JSON 中提取 message.content。

    结构校验失败、content 缺失或为空一律返回 None；reasoning_content
    字段不读取（忽略）。
    """
    if not isinstance(data, dict):
        return None
    choices = data.get('choices')
    if not isinstance(choices, list) or not choices:
        return None
    first = choices[0]
    if not isinstance(first, dict):
        return None
    message = first.get('message')
    if not isinstance(message, dict):
        return None
    content = message.get('content')
    if not isinstance(content, str) or not content.strip():
        return None
    return content


def call_ai(payload, base_url=None, api_key=None, model=None) -> str | None:
    """调用 OpenAI 兼容 /chat/completions 端点；任何失败返回 None（不抛异常）。

    base_url/api_key/model 缺省时依次回退环境变量 SDS_AI_BASE_URL /
    SDS_AI_API_KEY / SDS_AI_MODEL（model 再缺省 deepseek-v4-flash）。
    缺 base_url 直接降级返回 None，不发起请求。
    """
    if base_url is None:
        base_url = os.environ.get('SDS_AI_BASE_URL')
    if api_key is None:
        api_key = os.environ.get('SDS_AI_API_KEY')
    if model is None:
        model = os.environ.get('SDS_AI_MODEL') or _DEFAULT_MODEL
    if not base_url:
        return None  # 未配置后端：降级，绝不发起请求

    endpoint = base_url.rstrip('/') + '/chat/completions'
    body = json.dumps({
        'model': model,
        'messages': [{'role': 'user', 'content': payload}],
        'temperature': 0.3,
    }).encode('utf-8')
    headers = {'Content-Type': 'application/json'}
    if api_key:
        headers['Authorization'] = f'Bearer {api_key}'

    req = urllib.request.Request(endpoint, data=body, headers=headers, method='POST')
    resp = None
    try:
        resp = urllib.request.urlopen(req, timeout=_REQUEST_TIMEOUT)
        if getattr(resp, 'status', 200) != 200:
            return None
        data = json.loads(resp.read())
    except Exception:
        return None
    finally:
        if resp is not None:
            try:
                resp.close()
            except Exception:
                pass
    return _extract_content(data)
