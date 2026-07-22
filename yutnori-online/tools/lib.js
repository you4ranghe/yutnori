/* 검사 도구 공용 — index.html 에서 게임 코드를 꺼내 온다 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const HTML = path.join(ROOT, 'index.html');
const SQL = path.join(ROOT, 'schema.sql');

function html() { return fs.readFileSync(HTML, 'utf8'); }
function sql() { return fs.readFileSync(SQL, 'utf8'); }

/** index.html 안의 게임 스크립트 본문 */
function script() {
  const m = html().match(/<script>\n'use strict';([\s\S]*?)<\/script>/);
  if (!m) throw new Error('게임 스크립트를 찾지 못했습니다');
  return m[1];
}

/** 스크립트 앞부분의 상수 묶음 (말판 좌표 · 특별칸 등) */
function head(src) { return src.slice(0, src.indexOf('/* 이동 규칙')); }

/** 이름으로 함수 하나를 꺼낸다 (최상위 함수의 닫는 중괄호가 열 0 에 있다는 전제) */
function fn(src, name) {
  const at = src.indexOf('\nfunction ' + name + '(');
  if (at < 0) throw new Error('함수를 찾지 못했습니다: ' + name);
  const end = src.indexOf('\n}', at);
  if (end < 0) throw new Error('함수의 끝을 찾지 못했습니다: ' + name);
  return src.slice(at, end + 2);
}

/** `const NAME={...};` 형태의 상수를 꺼낸다 */
function konst(src, decl) {
  const at = src.indexOf(decl);
  if (at < 0) throw new Error('상수를 찾지 못했습니다: ' + decl);
  return src.slice(at, src.indexOf('\n', src.indexOf('};', at)) + 1);
}

/** 게임 규칙을 브라우저 없이 돌리기 위한 껍데기 */
const STUBS = `
const DIST_MEMO={};
let S=null,MA=null,hoverNode=null,curMove=null;
const sfx=new Proxy({},{get:()=>()=>{}});
function teamIcon(ti){return TEAM_ICON[ti]}
function log(){} function miniToast(){} function buzz(){} function updateUI(){}
function pushState(){} function showWinner(){}
function fxBig(){} function fxMini(){} function fxConf(){} function fxChime(){}
function fxSfx(){} function fxSide(){} function sideSfx(){} function fxSay(){} function playVoice(){}
function isMyTurn(){return true} function canAct(){return true}
`;

/** 규칙 계산에 필요한 함수 묶음 */
const RULE_FNS = ['computeDest','distToExit','resultOf','isLastGroup','chipUsable','enterSelect',
  'nodesFor','selectableNodes','canEnterWith','canEnter','previewDest','pickAtStart',
  'scoreMove','riskAt','moversAt','bestMove','executeMove','resolveMove','applySpecial','endTurn'];

/** 규칙만 담긴 실행 가능한 코드 문자열 */
function ruleCode(extra) {
  const src = script();
  return head(src)
    + konst(src, 'const AI_LEVELS=')
    + konst(src, 'const THROW_P=')
    + STUBS
    + RULE_FNS.map(n => fn(src, n)).join('\n')
    + (extra || '');
}

function ok(label) { console.log('✅  ' + label); }
function bad(label) { console.log('❌  ' + label); process.exitCode = 1; }
function check(label, cond) { cond ? ok(label) : bad(label); }

module.exports = { ROOT, HTML, SQL, html, sql, script, head, fn, konst, ruleCode, RULE_FNS, ok, bad, check };
