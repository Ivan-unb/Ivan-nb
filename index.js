/**
 * 宿主半边。
 *
 * 干三件事：把待办存成本机一个普通 JSON 文件；收桌面小窗投进来的文字、拆成条目；
 * 通过 /api/todo-note 这条 RPC 通道对外服务。
 *
 * 界面不在这里。桌面卡片是独立的 PowerShell/WPF 进程，两边只靠数据目录里的
 * request.json / result.json 交接——各自只写自己的文件，所以不用加锁。
 */

import { appendFile, mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import path from 'node:path'

const CHANNEL = 'todo-note'
const ROUTE = '/api/' + CHANNEL
const ENDPOINT_RE = /^[A-Za-z0-9_$.-]+$/
const RPC_ID_RE = /^[A-Za-z0-9_-]{1,128}$/

const DSH_HOME = process.env.DSH_HOME || path.join(homedir(), '.dsh')
const DATA_DIR = path.join(DSH_HOME, 'todo-note')
const DATA_FILE = path.join(DATA_DIR, 'todos.json')
const DIAG_FILE = path.join(DATA_DIR, 'diag.log')

const EMPTY_STATE = {
  version: 1,
  // 位置第一次由界面按窗口算（靠右上），这里只留空。
  note: null,
  seq: 0,
  items: [],
}

let cached = null

let dirReady = null

function ensureDir() {
  if (dirReady === null) dirReady = mkdir(DATA_DIR, { recursive: true }).catch(() => {})
  return dirReady
}

// 日志只往数据目录写。把可执行目录当日志落点，等于给每个用户装一个垃圾场，
// 而且那地方在 git 仓库里，一跑就脏。写不进去就丢掉，不为记日志把插件搞挂。
function diag(line) {
  const text = new Date().toISOString() + ' ' + line + '\n'
  ensureDir()
    .then(() => appendFile(DIAG_FILE, text, 'utf8'))
    .catch(() => {})

}

// 模块被 import 就会落这一行；apply 有没有被调用则是下一行。两行一对，
// 就能分清「没 import」还是「import 了但没 apply」。
diag('module-loaded dshHome=' + DSH_HOME)

function num(value, fallback) {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback
}

function str(value) {
  return typeof value === 'string' ? value : ''
}

function normalizeItem(raw) {
  if (raw === null || typeof raw !== 'object') return null
  const title = str(raw.title).trim()
  if (title === '') return null
  return {
    id: str(raw.id),
    title,
    place: str(raw.place),
    // 时间存绝对时刻（毫秒）与原话；没有时间就是 null，排序时沉底。
    time: typeof raw.time === 'number' && Number.isFinite(raw.time) ? raw.time : null,
    timeText: str(raw.timeText),
    done: raw.done === true,
    archived: raw.archived === true,
    createdAt: num(raw.createdAt, Date.now()),
  }
}

function normalizeState(raw) {
  const source = raw !== null && typeof raw === 'object' ? raw : {}
  const noteRaw = source.note !== null && typeof source.note === 'object' ? source.note : null
  const items = Array.isArray(source.items) ? source.items.map(normalizeItem).filter(Boolean) : []
  return {
    version: 1,
    note: noteRaw ? { x: num(noteRaw.x, 0), y: num(noteRaw.y, 0) } : null,
    seq: num(source.seq, items.length),
    items,
  }
}

async function loadState() {
  if (cached !== null) return cached
  try {
    const raw = await readFile(DATA_FILE, 'utf8')
    cached = normalizeState(JSON.parse(raw))
  } catch (err) {
    if (err && err.code !== 'ENOENT') throw err
    cached = normalizeState(null)
  }
  return cached
}

async function saveState(next) {
  const state = normalizeState(next)
  await mkdir(DATA_DIR, { recursive: true })
  const tmp = DATA_FILE + '.tmp'
  await writeFile(tmp, JSON.stringify(state, null, 2), 'utf8')
  await rename(tmp, DATA_FILE)
  cached = state
  return state
}

// ---------- 抽取 ----------
// 一段话进来，先拆成几件事，再逐条认时间、地点、事项。模型只负责「读」，
// 时间怎么落到毫秒由这里算，免得模型的时间口径和我们不一致。

const MAX_TEXT = 2000
const EXTRACT_TIMEOUT_MS = 45000

let hostCtx = null

const WEEKDAYS = ['日', '一', '二', '三', '四', '五', '六']

function pad2(n) {
  return String(n).padStart(2, '0')
}

function nowLine() {
  const d = new Date()
  return (
    d.getFullYear() +
    '年' +
    (d.getMonth() + 1) +
    '月' +
    d.getDate() +
    '日 星期' +
    WEEKDAYS[d.getDay()] +
    ' ' +
    pad2(d.getHours()) +
    ':' +
    pad2(d.getMinutes())
  )
}

function whenToEpoch(value) {
  const raw = str(value).trim()
  const m = /^(\d{4})-(\d{1,2})-(\d{1,2})(?:[T ](\d{1,2}):(\d{1,2}))?$/.exec(raw)
  if (!m) return null
  const d = new Date(
    Number(m[1]),
    Number(m[2]) - 1,
    Number(m[3]),
    m[4] ? Number(m[4]) : 0,
    m[5] ? Number(m[5]) : 0,
    0,
    0,
  )
  const t = d.getTime()
  return Number.isFinite(t) ? t : null
}

// 模型只给日期、不给钟点时（「明天上午交报告」），落库会变成当天 0 点，
// 摆在列表最上面很难看。按原话里的时段补一个合理的钟点，原话照样留着。
const DAY_PART_HOURS = [
  [/凌晨/, 5],
  [/清晨|早上|早晨/, 8],
  [/上午/, 9],
  [/中午|正午/, 12],
  [/下午/, 14],
  [/傍晚/, 18],
  [/晚上|夜里|明晚|今晚/, 19],
]

export function refineDayPart(time, whenText) {
  if (time === null || !whenText) return time
  const d = new Date(time)
  if (d.getHours() !== 0 || d.getMinutes() !== 0) return time
  for (const [re, hour] of DAY_PART_HOURS) {
    if (re.test(whenText)) {
      d.setHours(hour, 0, 0, 0)
      return d.getTime()
    }
  }
  return time
}

function firstSentence(text) {
  const cut = String(text).split(/[。！？!?\n；;]/)
  for (const piece of cut) {
    const t = piece.trim()
    if (t !== '') return t
  }
  return String(text).trim()
}

function readJsonObject(text) {
  const raw = String(text || '')
  const start = raw.indexOf('{')
  const end = raw.lastIndexOf('}')
  if (start < 0 || end <= start) return null
  try {
    return JSON.parse(raw.slice(start, end + 1))
  } catch {
    return null
  }
}

function buildPrompt(source) {
  const system = [
    '你是待办抽取器。用户会贴一段中文，你把它整理成若干条待办。',
    '现在是 ' + nowLine() + '（本机时区）。',
    '',
    '规则：',
    '1. 按「一件事」拆，不按动作拆。同一个活动里的各个步骤（签到、看比赛顺序、试讲、交材料）都属于同一件事，合成一条；只有原文确实写了两个互不相干的事，才拆成两条。',
    '2. 每条给五个字段：title（这件事的名字）、actions（具体要做哪几件事）、place（地点）、when 与 whenText（时间）、requirements（要求）。',
    '3. title 写这件事的名字，例如「2026年教师教学比武活动」。不带时间、不带地点、不带括号里的补充说明。',
    '4. actions 写为了这件事具体要做什么，从原文取短语，例如「签到」「查看比赛顺序」「现场授课」。两到四个就够，不要抄一整句，也不要把要求塞进来。原文本身就是单一动作、没什么可拆的（例如「还书」），actions 给空数组 []。',
    '5. requirements 收「照着做」的细则：要用的材料、必须包含的环节、时长和形式、纪律性要求（不得请假、必须全程参加、请提前做好安排）。一条一句，尽量照抄原文的句子，宁可多列一条，也不要压成一条长句。',
    '6. requirements 只收确实存在的。原文没有具体要求就写 []，不要编，也不要把时间和地点重复塞进来。',
    '7. when 用 "YYYY-MM-DDTHH:mm" 绝对格式，按上面的「现在」换算「明天」「下周三」这类说法；只知道日期就写 "YYYY-MM-DD"；没有时间写空串。',
    '8. whenText 抄原文里表示时间的那几个字，例如「明天下午三点」「11月21日（周六）上午8点45分签到，9点正式开始」。',
    '9. 整段话不是待办（闲聊、新闻、纯说明），返回 {"items":[]}。',
    '10. 只输出 JSON，不要解释，不要 Markdown 代码块。',
    '',
    '输出格式：{"items":[{"title":"","actions":[""],"place":"","when":"","whenText":"","requirements":[""]}]}',
  ].join('\n')
  return { system, user: source }
}

async function extract(text) {
  const source = str(text).trim()
  if (source === '') return { items: [], note: 'empty' }
  if (source.length > MAX_TEXT) return { items: [], note: 'too-long' }
  if (hostCtx === null) return { items: [], note: 'no-llm' }

  const llm = hostCtx.get('llm')
  if (!llm || typeof llm.stream !== 'function') return { items: [], note: 'no-llm' }

  const picker = hostCtx.get('agentDefaultModel')
  const rawPick = picker && typeof picker.currentSelection === 'function' ? picker.currentSelection() : null
  // 这个方法有同步返回的，也有返回 Promise 的，两种都接住。
  const selection = rawPick && typeof rawPick.then === 'function' ? await rawPick : rawPick
  if (!selection || !selection.provider || !selection.model) return { items: [], note: 'no-model' }

  const prompt = buildPrompt(source)
  const options = {
    provider: selection.provider,
    model: selection.model,
    messages: [{ role: 'user', content: [{ type: 'text', text: prompt.user }] }],
    system: prompt.system,
    maxTokens: 1600,
    sessionId: 'todo-note',
    purpose: 'todo-extract',
  }
  try {
    options.signal = AbortSignal.timeout(EXTRACT_TIMEOUT_MS)
  } catch {
    // 老 Node 没有 AbortSignal.timeout，就不设超时。
  }

  let said = ''
  try {
    for await (const chunk of llm.stream(options)) {
      if (!chunk || typeof chunk !== 'object') continue
      if (chunk.type === 'text-delta' && typeof chunk.text === 'string') said += chunk.text
      else if (chunk.type === 'finish' && chunk.reason) {
        const kind = chunk.reason.kind || chunk.reason
        if (kind !== 'stop') return { items: [], note: 'llm-' + String(kind) }
      }
    }
  } catch (err) {
    diag('extract-fail ' + String((err && err.message) || err))
    return { items: [], note: 'llm-error' }
  }

  const parsed = readJsonObject(said)
  if (parsed === null) {
    diag('extract-unparsable ' + said.slice(0, 200))
    return { items: [], note: 'llm-bad-json' }
  }

  const list = Array.isArray(parsed.items) ? parsed.items : []
  const items = []
  for (const raw of list) {
    if (raw === null || typeof raw !== 'object') continue
    const title = str(raw.title).trim() || firstSentence(source)
    const place = str(raw.place).trim()
    const whenText = str(raw.whenText).trim()
    // 要求是后加的第四维，老数据没有这个键；统一规整成字符串数组，别让界面去猜。
    const rawReqs = Array.isArray(raw.requirements) ? raw.requirements : []
    const requirements = []
    for (const one of rawReqs) {
      const line = str(one).trim()
      if (line === '') continue
      requirements.push(line.slice(0, 400))
      if (requirements.length >= 10) break
    }
    // 事项是几个短动作（签到、看顺序、试讲），跟标题分工：标题是这件事叫什么，事项是具体做什么。
    const rawActs = Array.isArray(raw.actions) ? raw.actions : []
    const actions = []
    for (const one of rawActs) {
      const line = str(one).trim()
      if (line === '') continue
      actions.push(line.slice(0, 80))
      if (actions.length >= 6) break
    }
    items.push({
      title, actions, place, time: refineDayPart(whenToEpoch(raw.when), whenText), timeText: whenText, requirements,
    })
    if (items.length >= 20) break
  }

  // 同一段话拆出来的几条，要求往往说的是同一批事。只在第一条上留着，
  // 其余的记下挂在哪一条上（reqOf 是本批下标），界面上显示成「要求见「…」」。
  const seenReq = new Map()
  for (let i = 0; i < items.length; i++) {
    const key = items[i].requirements.join('\u0001')
    if (key === '') continue
    if (seenReq.has(key)) {
      items[i].reqOf = seenReq.get(key)
      items[i].requirements = []
    } else {
      seenReq.set(key, i)
    }
  }

  if (items.length === 0) return { items: [], note: 'no-todo' }
  return { items, note: 'ok' }
}

async function dispatch(method, payload) {
  if (method === 'diag') {
    // 界面用这个探通道：谁能进来，谁就是能用的那条。
    return { ok: true, at: Date.now(), via: payload && payload.via ? String(payload.via) : 'unknown' }
  }
  if (method === 'parse.extract') return await extract(payload && payload.text)
  if (method === 'state.get') return await loadState()
  if (method === 'state.save') return await saveState(payload)
  throw new Error('unknown endpoint: ' + method)
}

function reply(rpcId, result) {
  return Response.json({ type: 'server-response', rpcId, result })
}

async function routeFetch(request) {
  if (!request || request.method !== 'POST') return new Response('method not allowed', { status: 405 })

  let body
  try {
    body = await request.json()
  } catch {
    diag('bad-body')
    return new Response('body is not JSON', { status: 400 })
  }

  const rpcId = body && typeof body.rpcId === 'string' && RPC_ID_RE.test(body.rpcId) ? body.rpcId : 'invalid-request'
  const call = body ? body.payload : null

  if (!body || body.type !== 'client-request' || rpcId === 'invalid-request') {
    diag('bad-request')
    return reply(rpcId, { ok: false, error: { code: 'gateway/bad-request', message: 'invalid client-request', details: {} } })
  }
  if (call === null || typeof call !== 'object' || typeof call.method !== 'string' || !ENDPOINT_RE.test(call.method)) {
    diag('bad-endpoint')
    return reply(rpcId, { ok: false, error: { code: 'gateway/bad-request', message: 'invalid endpoint', details: {} } })
  }

  const via = call.payload && typeof call.payload.via === 'string' ? ' via=' + call.payload.via : ''
  diag('call ' + call.method + via)
  try {
    return reply(rpcId, { ok: true, value: await dispatch(call.method, call.payload) })
  } catch (err) {
    diag('fail ' + call.method + ' ' + String((err && err.message) || err))
    return reply(rpcId, { ok: false, error: { code: 'internal', message: String((err && err.message) || err), details: {} } })
  }
}

const REQUEST_FILE = path.join(DATA_DIR, 'request.json')
const RESULT_FILE = path.join(DATA_DIR, 'result.json')

// 桌面小窗和这边只靠两个文件说话：它写 request.json（{id,text,at}），
// 我们读走、拆好、写回 result.json（{id,items,note,at}）。
// 各写各的文件，谁也不会覆盖谁，不需要锁。
let mailboxTimer = null
let mailboxBusy = false
let mailboxLastId = null

async function readJsonOrNull(file) {
  try {
    const raw = await readFile(file, 'utf8')
    if (!raw || !raw.trim()) return null
    return JSON.parse(raw)
  } catch {
    return null
  }
}

async function writeJsonAtomic(file, value) {
  await mkdir(DATA_DIR, { recursive: true })
  const tmp = file + '.tmp'
  await writeFile(tmp, JSON.stringify(value), 'utf8')
  await rename(tmp, file)
}

// 刚开机那几秒，模型服务可能还没就位；这时只失败一次就回话太急，再试一次。
async function extractWithRetry(text) {
  const out = await extract(text)
  if (out.note === 'llm-error' || out.note === 'no-llm' || out.note === 'no-model') {
    await new Promise((resolve) => setTimeout(resolve, 1500))
    return extract(text)
  }
  return out
}

async function mailboxTick() {
  if (mailboxBusy) return
  const req = await readJsonOrNull(REQUEST_FILE)
  if (!req || typeof req.id !== 'string' || req.id === mailboxLastId) return
  mailboxBusy = true
  mailboxLastId = req.id
  const text = typeof req.text === 'string' ? req.text : ''
  diag('mailbox take ' + req.id + ' len=' + text.length)
  try {
    const out = await extractWithRetry(text)
    await writeJsonAtomic(RESULT_FILE, {
      id: req.id,
      items: out.items,
      note: out.note,
      at: Date.now(),
    })
    diag('mailbox done ' + req.id + ' note=' + out.note + ' n=' + out.items.length)
  } catch (err) {
    diag('mailbox fail ' + req.id + ' ' + String((err && err.message) || err))
    // 失败也要回话，否则桌面那边只能等到超时，还不知道为什么。
    try {
      await writeJsonAtomic(RESULT_FILE, { id: req.id, items: [], note: 'llm-error', at: Date.now() })
    } catch {}
  } finally {
    mailboxBusy = false
  }
}

function startMailbox() {
  if (mailboxTimer) return
  mailboxTimer = setInterval(() => {
    mailboxTick()
  }, 1200)
  if (typeof mailboxTimer.unref === 'function') mailboxTimer.unref()
  diag('mailbox watching ' + REQUEST_FILE)
}

function tryRegister(scope) {
  const connection = scope && typeof scope.get === 'function' ? scope.get('connection') : undefined
  const registry = connection ? connection.fetch : undefined
  if (!registry || typeof registry.register !== 'function') {
    diag('fetch-register-missing')
    return false
  }
  try {
    const dispose = registry.register({ path: ROUTE, methods: ['POST'], requestBody: 'buffered', fetch: routeFetch })
    diag('registered ' + ROUTE)
    return true
  } catch (err) {
    // HMR 重载时同一条路由可能已经登记过，不算错误。
    diag('register-failed ' + String((err && err.message) || err))
    return false
  }
}

export function apply(ctx) {
  hostCtx = ctx
  diag('apply ' + ROUTE + ' dshHome=' + DSH_HOME + ' cwd=' + process.cwd())
  startMailbox()

  if (tryRegister(ctx)) return
  // connection 是别的插件提供的服务，apply 跑起来那一刻它可能还没就位。
  // 等它上线再注册，而不是当场放弃。
  if (typeof ctx.inject === 'function') {
    diag('awaiting connection')
    ctx.inject(['connection'], (scope) => {
      diag('connection-ready')
      tryRegister(scope)
    })
    return
  }
  diag('no-inject-api')
}
