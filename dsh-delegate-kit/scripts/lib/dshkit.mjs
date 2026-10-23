#!/usr/bin/env node
// dsh-delegate-kit: YAML / model catalog / patch helper for kit.ps1 and dsh-run.ps1.
// Only Node built-ins plus js-yaml bundled with the installed dsh package.
// stdout prints exactly one JSON object; on error prints {"error":"..."} and exits 1.

import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const THINKING_LEVELS = ['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'];

const DEFAULT_PLUGIN_IDS = {
  credentials: { id: 'credentials', name: '@deepseek-ai/dsh-credentials-local' },
  agentDefaultModel: { id: 'agent-default-model', name: '@deepseek-ai/dsh-agent-default-model' },
  compaction: { id: 'compaction-basic', name: '@deepseek-ai/dsh-compaction-basic' },
  browserUse: { id: 'browser-use', name: '@deepseek-ai/dsh-browser-use' },
  browserProvider: {
    id: 'browser-use-playwright-mcp',
    name: '@deepseek-ai/dsh-experimental-browser-use-playwright-mcp',
  },
  computerUse: { id: 'computer-use', name: '@deepseek-ai/dsh-computer-use' },
  computerProvider: {
    id: 'computer-use-cua-driver-native',
    name: '@deepseek-ai/dsh-experimental-computer-use-cua-driver-native',
  },
};

function fail(message) {
  const err = new Error(message);
  err.userFacing = true;
  throw err;
}

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (typeof token === 'string' && token.startsWith('--')) {
      const key = token.slice(2);
      const next = argv[i + 1];
      let value = true;
      if (next !== undefined && !(typeof next === 'string' && next.startsWith('--'))) {
        value = next;
        i += 1;
      }
      if (key === 'profile') {
        if (!Array.isArray(out.profile)) out.profile = [];
        out.profile.push(value);
      } else {
        out[key] = value;
      }
    } else {
      out._.push(token);
    }
  }
  return out;
}

function requireString(args, key, label) {
  const value = args[key];
  if (typeof value !== 'string' || value.length === 0) {
    fail(`缺少参数 --${key}${label ? `（${label}）` : ''}`);
  }
  return value;
}

function stripBom(text) {
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

function readText(file) {
  const buf = fs.readFileSync(file);
  // Accept UTF-8 (with/without BOM) as well as UTF-16 dumps written by Windows PowerShell redirection.
  if (buf.length >= 2 && buf[0] === 0xff && buf[1] === 0xfe) {
    return stripBom(buf.toString('utf16le'));
  }
  if (buf.length >= 2 && buf[0] === 0xfe && buf[1] === 0xff) {
    const swapped = Buffer.from(buf);
    swapped.swap16();
    return stripBom(swapped.toString('utf16le'));
  }
  return stripBom(buf.toString('utf8'));
}

function loadJsYaml(dshPkg) {
  const requireFromDsh = createRequire(path.join(dshPkg, 'package.json'));
  let mod;
  try {
    mod = requireFromDsh('js-yaml');
  } catch (err) {
    fail(`无法从 dsh 包加载 js-yaml：${err.message}`);
  }
  return mod.default && mod.default.load ? mod.default : mod;
}

// Locate the installed dsh package without requiring --dsh-pkg (parse-dump / gen-patches).
function locateDshPkg() {
  const candidates = [];
  if (typeof process.env.DSH_PKG === 'string' && process.env.DSH_PKG) {
    candidates.push(process.env.DSH_PKG);
  }
  const nodeDir = path.dirname(process.execPath);
  candidates.push(path.join(nodeDir, 'node_modules', '@deepseek-ai', 'dsh'));
  const pathDirs = (process.env.PATH || process.env.Path || '').split(path.delimiter);
  for (const dir of pathDirs) {
    if (!dir) continue;
    candidates.push(path.join(dir.trim(), 'node_modules', '@deepseek-ai', 'dsh'));
  }
  for (const candidate of candidates) {
    try {
      if (fs.existsSync(path.join(candidate, 'package.json'))) return path.resolve(candidate);
    } catch {
      // ignore malformed PATH entries
    }
  }
  return null;
}

function resolveDshPkg(args, required) {
  if (typeof args['dsh-pkg'] === 'string' && args['dsh-pkg']) return args['dsh-pkg'];
  const located = locateDshPkg();
  if (located) return located;
  if (required) fail('缺少参数 --dsh-pkg（也未能在 PATH 中定位已安装的 dsh）');
  fail('找不到已安装的 dsh（请传 --dsh-pkg）');
}

function createYaml(yaml) {
  // Same dialect as dsh itself (dsh-app-boot/lib/index.js): JSON_SCHEMA plus a !!js
  // scalar type that round-trips, so plain date-like strings stay strings and
  // `!!js <expr>` does not degrade into a mapping.
  const jsType = new yaml.Type('tag:yaml.org,2002:js', {
    kind: 'scalar',
    resolve: (data) => typeof data === 'string',
    construct: (s) => ({ js: s }),
    predicate: (data) =>
      data !== null &&
      typeof data === 'object' &&
      !Array.isArray(data) &&
      Object.keys(data).length === 1 &&
      typeof data.js === 'string',
    represent: (data) => data.js,
  });
  const schema = yaml.JSON_SCHEMA.extend([jsType]);
  return {
    load(text) {
      return yaml.load(text, { schema });
    },
    dump(value) {
      return yaml.dump(value, {
        lineWidth: -1,
        noRefs: true,
        schema,
      });
    },
  };
}

function readYamlFile(y, file, what) {
  let text;
  try {
    text = readText(file);
  } catch (err) {
    fail(`读取${what || ' YAML'}失败：${file}：${err.message}`);
  }
  try {
    return y.load(text);
  } catch (err) {
    fail(`解析${what || ' YAML'}失败：${file}：${err.message}`);
  }
}

function getCatalogPath(dshPkg) {
  const primary = path.join(
    dshPkg,
    'node_modules',
    '@earendil-works',
    'pi-ai',
    'dist',
    'models.generated.js',
  );
  if (fs.existsSync(primary)) return primary;
  try {
    const requireFromDsh = createRequire(path.join(dshPkg, 'package.json'));
    const pkgJson = requireFromDsh.resolve('@earendil-works/pi-ai/package.json');
    const candidate = path.join(path.dirname(pkgJson), 'dist', 'models.generated.js');
    if (fs.existsSync(candidate)) return candidate;
  } catch {
    // package not resolvable: catalog unavailable
  }
  return null;
}

let catalogCache = { path: undefined, models: null };

async function loadCatalog(dshPkg) {
  const catalogPath = getCatalogPath(dshPkg);
  if (catalogPath === null) {
    return { catalogPath: null, models: null };
  }
  if (catalogCache.path === catalogPath && catalogCache.models) {
    return { catalogPath, models: catalogCache.models };
  }
  try {
    const mod = await import(pathToFileURL(catalogPath).href);
    const models = mod.MODELS && typeof mod.MODELS === 'object' ? mod.MODELS : {};
    catalogCache = { path: catalogPath, models };
    return { catalogPath, models };
  } catch (err) {
    fail(`加载模型目录失败：${catalogPath}：${err.message}`);
  }
}

function catalogEntryOf(catalog, provider, id) {
  if (!catalog || !catalog[provider]) return null;
  const entry = catalog[provider][id];
  return entry && typeof entry === 'object' ? entry : null;
}

// Mirrors pi-ai dist/models.js getSupportedThinkingLevels (line ~680).
function supportedLevelsFromCatalog(entry) {
  if (!entry || !entry.reasoning) return ['off'];
  return THINKING_LEVELS.filter((level) => {
    const mapped = entry.thinkingLevelMap?.[level];
    if (mapped === null) return false;
    if (level === 'xhigh' || level === 'max') return mapped !== undefined;
    return true;
  });
}

// Mirrors dsh-llm-pi-ai resolveModelReasoning: `false`, or a non-empty dict whose
// declared keys are the offered levels. `null`, `{}`, `true` and other shapes make
// dsh reject the profile on load, so they must not be reported as a capability.
function parseDeclaredEfforts(declared) {
  if (declared === false) return { valid: true, levels: ['off'], reasoning: false };
  if (declared === null || typeof declared !== 'object' || Array.isArray(declared)) {
    return { valid: false };
  }
  if (Object.keys(declared).length === 0) return { valid: false };
  const levels = THINKING_LEVELS.filter((level) => {
    const wire = declared[level];
    if (wire === undefined) return false;
    if (wire === null) return level === 'off';
    return true;
  });
  return { valid: true, levels, reasoning: true };
}

function buildModelInfo(provider, id, entry, entrySource, catalog, warnings) {
  const catalogEntry = catalogEntryOf(catalog, provider, id);
  const declared = entry ? entry.reasoningEfforts : undefined;
  let efforts = null;
  let effortsKnown = false;
  let reasoning = null;
  let capabilitySource;

  if (declared !== undefined) {
    const parsed = parseDeclaredEfforts(declared);
    if (parsed.valid) {
      efforts = parsed.levels.filter((level) => level !== 'off');
      effortsKnown = true;
      reasoning = parsed.reasoning;
      capabilitySource = 'profile-declared';
    } else {
      const where = entrySource ? `profile=${entrySource} 的 ` : '';
      warnings.push(
        `${where}${provider}/${id} 的 reasoningEfforts 写法无效（dsh 只接受 false 或非空对象），思考等级未知`,
      );
      efforts = null;
      effortsKnown = false;
      reasoning = null;
      capabilitySource = 'profile-fallback';
    }
  } else if (catalogEntry) {
    const levels = supportedLevelsFromCatalog(catalogEntry);
    efforts = levels.filter((level) => level !== 'off');
    effortsKnown = true;
    reasoning = Boolean(catalogEntry.reasoning);
    capabilitySource = 'catalog';
  } else {
    efforts = null;
    effortsKnown = false;
    reasoning = null;
    capabilitySource = 'profile-fallback';
    warnings.push(
      `模型目录里查不到 ${provider}/${id}，思考等级未知${catalog ? '' : '（模型目录不可用）'}`,
    );
  }

  const rawInput = entry?.input ?? catalogEntry?.input;
  const input = Array.isArray(rawInput) ? rawInput.slice() : [];
  const contextWindow =
    typeof entry?.contextWindow === 'number'
      ? entry.contextWindow
      : typeof catalogEntry?.contextWindow === 'number'
        ? catalogEntry.contextWindow
        : null;
  const maxTokens =
    typeof entry?.maxTokens === 'number'
      ? entry.maxTokens
      : typeof catalogEntry?.maxTokens === 'number'
        ? catalogEntry.maxTokens
        : null;
  const name =
    typeof entry?.name === 'string'
      ? entry.name
      : typeof catalogEntry?.name === 'string'
        ? catalogEntry.name
        : id;

  return {
    provider,
    id,
    name,
    plugin: null,
    pluginName: null,
    sources: [],
    isDefaultIn: [],
    contextWindow,
    maxTokens,
    input,
    vision: input.includes('image'),
    reasoning,
    efforts,
    effortsKnown,
    capabilitySource,
    catalogFound: Boolean(catalogEntry),
  };
}

function modelEntriesOf(rawModels) {
  if (Array.isArray(rawModels)) {
    return rawModels.filter((m) => m && typeof m === 'object');
  }
  if (rawModels && typeof rawModels === 'object') {
    return Object.entries(rawModels).map(([id, value]) =>
      value && typeof value === 'object' ? { id, ...value } : { id },
    );
  }
  return [];
}

function collectProfileModels(parsed, profileName, warnings, records, defaults) {
  const entries = Array.isArray(parsed) ? parsed : [];
  for (const entry of entries) {
    if (!entry || typeof entry !== 'object') continue;
    const name = typeof entry.name === 'string' ? entry.name : '';
    const id = typeof entry.id === 'string' ? entry.id : '';

    if (name === '@deepseek-ai/dsh-llm-pi-ai') {
      const providers = entry.config?.providers;
      if (!providers || typeof providers !== 'object') continue;
      for (const [provider, providerConfig] of Object.entries(providers)) {
        if (!providerConfig || typeof providerConfig !== 'object') continue;
        for (const model of modelEntriesOf(providerConfig.models)) {
          if (typeof model.id !== 'string' || !model.id) continue;
          addRecord(records, profileName, provider, model.id, model, entry, 'pi');
        }
        // dsh-llm-pi-ai also serves `providers.<p>.modelOverrides.<id>` (id is the dict
        // key); such a model is invisible in the `models` list but still configurable.
        const overrides = providerConfig.modelOverrides;
        if (overrides && typeof overrides === 'object' && !Array.isArray(overrides)) {
          for (const [modelId, override] of Object.entries(overrides)) {
            if (!modelId) {
              warnings.push(`profile=${profileName} 的 provider ${provider} 有空的 modelOverrides 键，已忽略`);
              continue;
            }
            if (!override || typeof override !== 'object' || Array.isArray(override)) {
              warnings.push(
                `profile=${profileName} 的 ${provider}/${modelId} modelOverrides 不是对象，已忽略`,
              );
              continue;
            }
            addRecord(records, profileName, provider, modelId, override, entry, 'override');
          }
        }
      }
    } else if (name === '@deepseek-ai/dsh-llm-deepseek-api-key') {
      for (const model of modelEntriesOf(entry.config?.models)) {
        if (typeof model.id !== 'string' || !model.id) continue;
        addRecord(records, profileName, 'deepseek-official', model.id, model, entry, 'deepseek');
      }
    } else if (name.startsWith('@deepseek-ai/dsh-llm-') && name !== '@deepseek-ai/dsh-agent-default-model') {
      warnings.push(
        `暂不支持的 LLM 插件条目（id=${id || '?'} name=${name}，profile=${profileName}），未列出其模型`,
      );
    }
  }

  for (const entry of entries) {
    if (!entry || typeof entry !== 'object') continue;
    if (entry.name !== '@deepseek-ai/dsh-agent-default-model') continue;
    const provider = entry.config?.provider;
    const model = entry.config?.model;
    if (typeof provider !== 'string' || typeof model !== 'string') {
      warnings.push(`profile=${profileName} 的 agent-default-model 配置不完整，已忽略`);
      continue;
    }
    const reasoningEffort =
      typeof entry.config?.reasoningEffort === 'string' ? entry.config.reasoningEffort : null;
    defaults.push({ source: profileName, provider, model, reasoningEffort });
    addRecord(records, profileName, provider, model, null, null, 'default');
    const rec = records.get(`${provider}/${model}`);
    if (rec && !rec.isDefaultIn.includes(profileName)) rec.isDefaultIn.push(profileName);
  }
}

function addRecord(records, profileName, provider, id, modelEntry, pluginEntry, kind) {
  const key = `${provider}/${id}`;
  let rec = records.get(key);
  if (!rec) {
    rec = {
      provider,
      id,
      entries: [],
      plugin: pluginEntry && typeof pluginEntry.id === 'string' ? pluginEntry.id : null,
      pluginName: pluginEntry && typeof pluginEntry.name === 'string' ? pluginEntry.name : null,
      sources: [],
      isDefaultIn: [],
      kind,
    };
    records.set(key, rec);
  }
  if (modelEntry) rec.entries.push({ profile: profileName, entry: modelEntry });
  if (!rec.plugin && pluginEntry && typeof pluginEntry.id === 'string') rec.plugin = pluginEntry.id;
  if (!rec.pluginName && pluginEntry && typeof pluginEntry.name === 'string') {
    rec.pluginName = pluginEntry.name;
  }
  if (!rec.sources.includes(profileName)) rec.sources.push(profileName);
}

// The profile setup uses to build the provider patch: web first, then desktop,
// then whatever profile listed the model first (see setup.ps1 sourceProfile choice).
function primarySourceOf(sources) {
  if (sources.includes('web')) return 'web';
  if (sources.includes('desktop')) return 'desktop';
  return sources.length > 0 ? sources[0] : null;
}

// Capabilities, contextWindow and input all come from that single entry; never
// stitch fields from different profiles (dsh will only see the primary one).
function pickEntry(rec) {
  const source = primarySourceOf(rec.sources);
  if (!source) return null;
  const found = rec.entries.find((item) => item.profile === source);
  return found ? found.entry : null;
}

async function cmdModels(args) {
  const dshPkg = requireString(args, 'dsh-pkg');
  const profiles = Array.isArray(args.profile) ? args.profile : [];
  const warnings = [];
  const records = new Map();
  const defaults = [];
  const y = createYaml(loadJsYaml(dshPkg));
  const { catalogPath, models: catalog } = await loadCatalog(dshPkg);
  if (!catalogPath) warnings.push('模型目录不可用，所有模型按“目录查不到”处理');

  const seenProfiles = new Set();
  for (const spec of profiles) {
    if (typeof spec !== 'string' || !spec.includes('=')) {
      fail(`--profile 需要 name=path 形式，收到：${String(spec)}`);
    }
    const eq = spec.indexOf('=');
    const name = spec.slice(0, eq);
    const file = spec.slice(eq + 1);
    if (!name) fail(`--profile 名称不能为空：${spec}`);
    if (seenProfiles.has(name)) {
      warnings.push(`profile 重复指定，已跳过：${name}`);
      continue;
    }
    seenProfiles.add(name);
    if (!fs.existsSync(file)) {
      warnings.push(`profile 不存在，已跳过：${name}（${file}）`);
      continue;
    }
    const parsed = readYamlFile(y, file, ` profile（${name}）`);
    if (!Array.isArray(parsed)) {
      fail(`profile 顶层不是数组：${file}`);
    }
    collectProfileModels(parsed, name, warnings, records, defaults);
  }

  const models = [];
  for (const rec of records.values()) {
    const info = buildModelInfo(
      rec.provider,
      rec.id,
      pickEntry(rec),
      primarySourceOf(rec.sources),
      catalog,
      warnings,
    );
    info.plugin = rec.plugin;
    info.pluginName = rec.pluginName;
    info.sources = rec.sources.slice();
    info.isDefaultIn = rec.isDefaultIn.slice();
    models.push(info);
  }

  return { catalogPath: catalogPath ?? null, models, defaults, warnings };
}

async function cmdCatalog(args) {
  const dshPkg = requireString(args, 'dsh-pkg');
  const provider = requireString(args, 'provider');
  const model = requireString(args, 'model');
  const { catalogPath, models: catalog } = await loadCatalog(dshPkg);
  const entry = catalogEntryOf(catalog, provider, model);
  if (!entry) {
    return {
      catalogPath: catalogPath ?? null,
      found: false,
      reasoning: null,
      efforts: null,
      contextWindow: null,
      input: null,
    };
  }
  const levels = supportedLevelsFromCatalog(entry);
  return {
    catalogPath,
    found: true,
    reasoning: Boolean(entry.reasoning),
    efforts: levels.filter((level) => level !== 'off'),
    contextWindow: typeof entry.contextWindow === 'number' ? entry.contextWindow : null,
    input: Array.isArray(entry.input) ? entry.input.slice() : [],
  };
}

function cmdParseDump(args) {
  const file = requireString(args, 'file');
  if (!fs.existsSync(file)) fail(`dump 文件不存在：${file}`);
  const dshPkg = resolveDshPkg(args, false);
  const yaml = createYaml(loadJsYaml(dshPkg));
  const parsed = readYamlFile(yaml, file, ' dump');
  const rows = Array.isArray(parsed) ? parsed : fail(`dump 顶层不是数组：${file}`);
  const entries = [];
  for (const row of rows) {
    if (!row || typeof row !== 'object') continue;
    if (typeof row.id !== 'string' || !row.id) continue;
    entries.push({
      id: row.id,
      name: typeof row.name === 'string' ? row.name : null,
      disabled: normalizeDisabled(row.disabled),
      config:
        row.config && typeof row.config === 'object' && !Array.isArray(row.config)
          ? row.config
          : row.config === undefined || row.config === null
            ? null
            : row.config,
    });
  }
  return { entries };
}

function normalizeDisabled(value) {
  if (value === undefined) return null;
  if (typeof value === 'boolean') return value;
  if (value && typeof value === 'object' && typeof value.js === 'string') {
    return { js: value.js };
  }
  return null;
}

function findSourceEntry(parsed, spec) {
  const rows = Array.isArray(parsed) ? parsed : [];
  if (typeof spec.pluginName === 'string' && spec.pluginName) {
    const byName = rows.find((e) => e && typeof e === 'object' && e.name === spec.pluginName);
    if (byName) return byName;
  }
  if (typeof spec.plugin === 'string' && spec.plugin) {
    const byId = rows.find((e) => e && typeof e === 'object' && e.id === spec.plugin);
    if (byId) return byId;
  }
  return null;
}

// Models only reachable through agent-default-model carry no plugin id; look for any
// provider entry that actually serves the model so its config can still be extracted.
function findProviderEntryForModel(parsed, spec) {
  const rows = Array.isArray(parsed) ? parsed : [];
  for (const entry of rows) {
    if (!entry || typeof entry !== 'object') continue;
    if (entry.name === '@deepseek-ai/dsh-llm-pi-ai') {
      const providerConfig = entry.config?.providers?.[spec.provider];
      if (!providerConfig || typeof providerConfig !== 'object') continue;
      const inModels = modelEntriesOf(providerConfig.models).some((m) => m.id === spec.model);
      const overrides = providerConfig.modelOverrides;
      const inOverrides =
        overrides && typeof overrides === 'object'
          ? Object.prototype.hasOwnProperty.call(overrides, spec.model)
          : false;
      if (inModels || inOverrides) return entry;
    } else if (entry.name === '@deepseek-ai/dsh-llm-deepseek-api-key') {
      if (spec.provider !== 'deepseek-official') continue;
      if (modelEntriesOf(entry.config?.models).some((m) => m.id === spec.model)) return entry;
    }
  }
  return null;
}

function buildProviderEntry(sourceEntry, spec) {
  const id = typeof sourceEntry.id === 'string' ? sourceEntry.id : spec.plugin;
  const name = typeof sourceEntry.name === 'string' ? sourceEntry.name : spec.pluginName;
  const config = sourceEntry.config;
  if (!config || typeof config !== 'object') {
    fail(`来源 profile 中 ${id} 缺少 config，无法提取服务商配置`);
  }

  if (name === '@deepseek-ai/dsh-llm-pi-ai') {
    const providerConfig = config.providers?.[spec.provider];
    if (!providerConfig || typeof providerConfig !== 'object') {
      fail(`来源 profile 中找不到 provider：${spec.provider}`);
    }
    const models = modelEntriesOf(providerConfig.models);
    const overrides = providerConfig.modelOverrides;
    const served =
      models.some((m) => m.id === spec.model) ||
      (overrides && typeof overrides === 'object'
        ? Object.prototype.hasOwnProperty.call(overrides, spec.model)
        : false);
    if (!served) {
      fail(`来源 profile 中 provider ${spec.provider} 下找不到模型：${spec.model}`);
    }
    return { id, name, config: { providers: { [spec.provider]: providerConfig } } };
  }

  const models = modelEntriesOf(config.models);
  if (!models.some((m) => m.id === spec.model)) {
    fail(`来源 profile 中找不到模型：${spec.provider}/${spec.model}`);
  }
  return { id, name, config };
}

function round4(n) {
  return Math.round(n * 10000) / 10000;
}

function computeCompaction(contextWindow) {
  if (typeof contextWindow !== 'number' || !Number.isFinite(contextWindow) || contextWindow <= 0) {
    return {
      entry: null,
      applied: false,
      thresholdRatio: null,
      retainTokens: null,
      reason: '上下文窗口未知',
    };
  }
  const ratioRaw = 200000 / contextWindow;
  if (ratioRaw > 0.8) {
    return {
      entry: null,
      applied: false,
      thresholdRatio: null,
      retainTokens: null,
      reason: `上下文窗口 ${contextWindow} 小于 25 万，保持默认压缩阈值`,
    };
  }
  const thresholdRatio = round4(ratioRaw);
  const budget = thresholdRatio * contextWindow;
  let retainTokens = 60000;
  if (!(retainTokens < budget)) retainTokens = Math.floor(budget * 0.3);
  return {
    entry: { thresholdRatio, retainTokens },
    applied: true,
    thresholdRatio,
    retainTokens,
    reason: '',
  };
}

function writeYamlFile(y, file, comments, value) {
  const body = y.dump(value);
  const text = `${comments.join('\n')}\n${body}`;
  fs.writeFileSync(file, text, 'utf8');
}

async function cmdGenPatches(args) {
  const specFile = requireString(args, 'spec');
  const outDir = path.resolve(requireString(args, 'out'));
  if (!fs.existsSync(specFile)) fail(`spec 文件不存在：${specFile}`);
  let spec;
  try {
    spec = JSON.parse(readText(specFile));
  } catch (err) {
    fail(`读取 spec.json 失败：${err.message}`);
  }
  if (!spec || typeof spec !== 'object') fail('spec.json 内容不是对象');
  if (typeof spec.sourceProfile !== 'string' || !spec.sourceProfile) {
    fail('spec.sourceProfile 缺失');
  }
  if (typeof spec.provider !== 'string' || !spec.provider) fail('spec.provider 缺失');
  if (typeof spec.model !== 'string' || !spec.model) fail('spec.model 缺失');
  if (!fs.existsSync(spec.sourceProfile)) {
    fail(`来源 profile 不存在：${spec.sourceProfile}`);
  }

  const dshPkg = resolveDshPkg(args, true);
  const y = createYaml(loadJsYaml(dshPkg));
  const source = readYamlFile(y, spec.sourceProfile, '来源 profile');
  if (!Array.isArray(source)) fail(`来源 profile 顶层不是数组：${spec.sourceProfile}`);

  const warnings = [];
  const hasPluginSpec =
    (typeof spec.plugin === 'string' && spec.plugin.length > 0) ||
    (typeof spec.pluginName === 'string' && spec.pluginName.length > 0);
  let sourceEntry = findSourceEntry(source, spec);
  if (!sourceEntry && !hasPluginSpec) {
    sourceEntry = findProviderEntryForModel(source, spec);
    if (!sourceEntry) {
      warnings.push(
        `来源 profile 中没有 ${spec.provider}/${spec.model} 的服务商插件条目，已省略服务商配置（沿用 dsh 内置配置）`,
      );
    }
  }
  if (!sourceEntry && hasPluginSpec) {
    fail(`来源 profile 中找不到插件：${spec.pluginName || spec.plugin}`);
  }
  const providerEntry = sourceEntry ? buildProviderEntry(sourceEntry, spec) : null;

  const ids = { ...DEFAULT_PLUGIN_IDS };
  if (spec.pluginIds && typeof spec.pluginIds === 'object') {
    for (const [key, value] of Object.entries(spec.pluginIds)) {
      if (!DEFAULT_PLUGIN_IDS[key] || !value || typeof value !== 'object') continue;
      ids[key] = {
        id: typeof value.id === 'string' ? value.id : DEFAULT_PLUGIN_IDS[key].id,
        name: typeof value.name === 'string' ? value.name : DEFAULT_PLUGIN_IDS[key].name,
      };
    }
  }

  const defaultEffort =
    typeof spec.defaultEffort === 'string' && spec.defaultEffort ? spec.defaultEffort : null;
  const contextWindow =
    typeof spec.contextWindow === 'number' && Number.isFinite(spec.contextWindow)
      ? spec.contextWindow
      : null;
  const browserAvailable = spec.browserAvailable === true;
  const chromePath =
    typeof spec.chromePath === 'string' && spec.chromePath.length > 0 ? spec.chromePath : null;

  fs.mkdirSync(outDir, { recursive: true });

  // ---- base.yml (layer 1) ----
  const base = [{ ...ids.credentials, disabled: false }];
  if (providerEntry) base.push(providerEntry);
  const defaultConfig = { provider: spec.provider, model: spec.model };
  if (defaultEffort !== null) defaultConfig.reasoningEffort = defaultEffort;
  base.push({ ...ids.agentDefaultModel, config: defaultConfig });

  const compaction = computeCompaction(contextWindow);
  if (compaction.applied) {
    base.push({ ...ids.compaction, config: { ...compaction.entry } });
  }

  let browserWritten = false;
  if (browserAvailable) {
    const providerConfig = { mode: 'launch', headless: true };
    if (chromePath) providerConfig.executablePath = chromePath;
    base.push({
      insert: [
        { id: ids.browserUse.id, name: ids.browserUse.name },
        { id: ids.browserProvider.id, name: ids.browserProvider.name, config: providerConfig },
      ],
    });
    browserWritten = true;
  }

  const browserNote = browserAvailable
    ? chromePath
      ? `浏览器插件使用 Chrome：${chromePath}`
      : '浏览器插件使用默认浏览器路径'
    : '浏览器不可用，本文件不插入浏览器插件';
  const baseComments = [
    '# dsh-delegate-kit 基础补丁（第 1 层，最先叠加）',
    providerEntry
      ? '# 启用凭证插件，带上所选模型的服务商配置、默认模型与压缩参数'
      : '# 启用凭证插件，带上默认模型与压缩参数（服务商配置沿用 dsh 内置）',
    `# ${browserNote}；叠加顺序：base -> effort-<档> -> no-browser -> computer-use`,
  ];
  const baseFile = path.join(outDir, 'base.yml');
  writeYamlFile(y, baseFile, baseComments, base);

  // ---- effort-<level>.yml (layer 2) ----
  const effortFiles = {};
  const efforts = Array.isArray(spec.efforts) ? spec.efforts.filter((e) => typeof e === 'string') : [];
  for (const effort of efforts) {
    if (effort === defaultEffort) continue;
    if (effortFiles[effort]) continue;
    const file = path.join(outDir, `effort-${effort}.yml`);
    const value = [
      {
        ...ids.agentDefaultModel,
        config: { provider: spec.provider, model: spec.model, reasoningEffort: effort },
      },
    ];
    writeYamlFile(
      y,
      file,
      [
        `# dsh-delegate-kit 思考档补丁：${effort}（第 2 层）`,
        '# 在 base.yml 之后叠加，覆盖 agent-default-model 的 reasoningEffort',
      ],
      value,
    );
    effortFiles[effort] = file;
  }

  // ---- no-browser.yml (layer 3) ----
  const noBrowserFile = path.join(outDir, 'no-browser.yml');
  writeYamlFile(
    y,
    noBrowserFile,
    [
      '# dsh-delegate-kit 浏览器禁用补丁（第 3 层）',
      '# 在 base/effort 之后叠加，只禁用两个浏览器插件、不改动其配置',
    ],
    [
      { id: ids.browserUse.id, name: ids.browserUse.name, disabled: true },
      { id: ids.browserProvider.id, name: ids.browserProvider.name, disabled: true },
    ],
  );

  // ---- computer-use.yml (layer 4) ----
  const computerUseFile = path.join(outDir, 'computer-use.yml');
  writeYamlFile(
    y,
    computerUseFile,
    [
      '# dsh-delegate-kit 电脑操作补丁（第 4 层，最后叠加）',
      '# 插入 computer-use 与 cua-driver 原生驱动插件',
    ],
    [
      {
        insert: [
          { id: ids.computerUse.id, name: ids.computerUse.name },
          { id: ids.computerProvider.id, name: ids.computerProvider.name },
        ],
      },
    ],
  );

  return {
    files: {
      base: baseFile,
      effort: effortFiles,
      noBrowser: noBrowserFile,
      computerUse: computerUseFile,
    },
    compaction: {
      applied: compaction.applied,
      thresholdRatio: compaction.thresholdRatio,
      retainTokens: compaction.retainTokens,
      reason: compaction.reason,
    },
    browser: { written: browserWritten },
    providerEntry: providerEntry !== null,
    warnings,
  };
}

function main() {
  const [command, ...rest] = process.argv.slice(2);
  const args = parseArgs(rest);
  if (!command) fail('缺少子命令（models | catalog | parse-dump | gen-patches）');
  switch (command) {
    case 'models':
      return cmdModels(args);
    case 'catalog':
      return cmdCatalog(args);
    case 'parse-dump':
      return cmdParseDump(args);
    case 'gen-patches':
      return cmdGenPatches(args);
    default:
      fail(`未知子命令：${command}`);
  }
}

try {
  const result = await main();
  process.stdout.write(`${JSON.stringify(result)}\n`);
} catch (err) {
  const message = err && err.message ? err.message : String(err);
  process.stdout.write(`${JSON.stringify({ error: message })}\n`);
  process.exitCode = 1;
}
