/* 전체 검사 — node tools/검사.js
   1) 문법  2) 화면 요소 참조  3) 스키마 구조  4) 게임 규칙 시뮬레이션 */
const vm = require('vm');
const L = require('./lib');

let fail = 0;
const section = t => console.log('\n── ' + t + ' ' + '─'.repeat(Math.max(0, 34 - t.length)));
const ok = m => console.log('✅  ' + m);
const bad = m => { console.log('❌  ' + m); fail++; };

/* ---------- 1. 문법 ---------- */
section('문법');
try {
  new vm.Script(L.script(), { filename: 'game.js' });
  ok('게임 스크립트 (' + (L.script().length / 1024).toFixed(0) + ' KB)');
} catch (e) { bad('게임 스크립트: ' + e.message); }
try {
  const fs = require('fs');
  new vm.Script(fs.readFileSync(L.ROOT + '/config.js', 'utf8'));
  ok('config.js');
  new vm.Script(fs.readFileSync(L.ROOT + '/sw.js', 'utf8'));
  ok('sw.js');
} catch (e) { bad(e.message); }

/* ---------- 2. 화면 요소 참조 ---------- */
section('화면 요소');
{
  const h = L.html(), s = L.script();
  const markup = h.slice(0, h.indexOf('<script src="./config.js">'));
  const defined = new Set([...markup.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]));
  const used = [...new Set([...s.matchAll(/\$\('([^']+)'\)/g)].map(m => m[1]))];
  const missing = used.filter(id => !defined.has(id));
  missing.length ? bad('없는 id: ' + missing.join(', ')) : ok('고정 id ' + used.length + '개 모두 존재');

  const dyn = [...new Set([...s.matchAll(/\$\('([a-zA-Z]+)'\+\w+\)/g)].map(m => m[1]))];
  const dynMissing = dyn.flatMap(b => [0, 1].filter(i => !defined.has(b + i)).map(i => b + i));
  dynMissing.length ? bad('없는 동적 id: ' + dynMissing.join(', ')) : ok('동적 id (' + dyn.join(', ') + ') 존재');

  const classes = new Set([...markup.matchAll(/class="([^"]+)"/g)].flatMap(m => m[1].split(/\s+/)));
  [...s.matchAll(/className\s*=\s*'([^']+)'/g)].forEach(m => m[1].split(/\s+/).forEach(c => classes.add(c)));
  [...s.matchAll(/classList\.(?:add|toggle)\('([^']+)'/g)].forEach(m => classes.add(m[1]));
  const badSel = [...new Set([...s.matchAll(/querySelector(?:All)?\('\.([\w-]+)'\)/g)].map(m => m[1]))]
    .filter(c => !classes.has(c));
  badSel.length ? bad('없는 클래스: ' + badSel.join(', ')) : ok('셀렉터 클래스 확인');
}

/* ---------- 3. 스키마 구조 ---------- */
section('스키마');
{
  const s = L.sql();
  const d = (s.match(/\$\$/g) || []).length;
  d % 2 === 0 ? ok('$$ 구분자 짝 (' + d + ')') : bad('$$ 구분자 홀수 (' + d + ')');
  /^begin;/m.test(s) && /^commit;/m.test(s) ? ok('트랜잭션으로 묶임') : bad('트랜잭션 begin/commit 없음');

  let unbalanced = 0;
  s.split('create or replace function').slice(1).forEach(b => {
    const body = b.slice(0, b.indexOf('$$', b.indexOf('$$') + 2) + 2);
    if ((body.match(/\bbegin\b/g) || []).length > (body.match(/\bend\b/g) || []).length) unbalanced++;
  });
  unbalanced ? bad('함수 begin/end 불균형 ' + unbalanced + '건') : ok('함수 begin/end 균형');

  // grant 목록에 빠진 공개 함수가 없는지
  const grantPart = s.slice(s.indexOf('grant execute on function'));
  const pub = [...s.matchAll(/create or replace function public\.(\w+)/g)]
    .map(m => m[1]).filter(n => !n.startsWith('_'));
  const notGranted = pub.filter(n => !grantPart.includes('public.' + n + '('));
  notGranted.length ? bad('권한 없는 공개 함수: ' + notGranted.join(', '))
                    : ok('공개 함수 ' + pub.length + '개 모두 권한 부여');
}

/* ---------- 4. 게임 규칙 ---------- */
section('게임 규칙');
{
  const code = L.ruleCode(`
    function mkState(o){
      const mk=ti=>({name:'T'+ti,icon:TEAM_ICON[ti],color:'#000',deep:'#000',
        players:[{uid:'p'+ti,name:'P'+ti}],pIdx:0,
        pieces:Array.from({length:o.pieceCount},(_,k)=>({id:k,node:null,done:false,hist:[]}))});
      return {gid:'t',ver:1,teams:[mk(0),mk(1)],cur:0,throwsLeft:1,pending:[],
              phase:'throw',sel:0,backdo:o.backdo,special:o.special,winner:null,logs:[]};
    }
    function play(o,lvA,lvB){
      S=mkState(o);MA=null;let g=0,throws=0;
      while(S.winner===null){
        if(++g>20000)return {err:'끝나지 않음'};
        if(S.phase==='throw'){
          const f=[0,1,2,3].map(()=>Math.random()<0.57),r=resultOf(f);
          throws++;S.throwsLeft--;S.pending.push({name:r[0],steps:r[1]});
          if(r[1]>=4)S.throwsLeft++;
          if(S.throwsLeft===0)enterSelect();
        }else if(S.phase==='select'){
          const m=bestMove(S.cur===0?lvA:lvB);
          if(!m)return {err:'둘 수 있는 수 없음'};
          S.sel=m.chipIdx;executeMove(m.target);
          let k=0;while(MA){if(++k>50)return {err:'애니메이션 무한'};const cb=MA.cb;MA=null;cb();}
        }else return {err:'예상 못한 단계 '+S.phase};
      }
      return {winner:S.winner,throws};
    }
    const out={games:0,fail:0,wins:[0,0],throws:0,errs:[]};
    [{pieceCount:4,backdo:true,special:true},{pieceCount:2,backdo:false,special:false},
     {pieceCount:5,backdo:true,special:false}].forEach(o=>{
      for(let i=0;i<200;i++){
        const r=play(o,'best','best');out.games++;
        if(r.err){out.fail++;if(out.errs.length<3)out.errs.push(r.err);}
        else{out.wins[r.winner]++;out.throws+=r.throws;}
      }
    });
    /* 출발·도착 칸 선택 */
    S=mkState({pieceCount:4,backdo:true,special:true});
    S.phase='select';S.throwsLeft=0;
    S.teams[0].pieces[0].node=0;S.teams[0].pieces[0].hist=[0,1,2,3,4,5];
    S.pending=[{name:'개',steps:2}];
    out.pick0={선택가능:selectableNodes().includes(0),새말가능:canEnter(),고르기:pickAtStart()};
    /* 난이도 사다리 */
    const ladder=(a,b,n)=>{let wa=0,wb=0;for(let i=0;i<n;i++){const r=play({pieceCount:4,backdo:true,special:true},a,b);if(!r.err)(r.winner===0?wa++:wb++);}return wa/(wa+wb);};
    out.hardVsNormal=ladder('hard','normal',800);
    out.normalVsEasy=ladder('normal','easy',400);
    JSON.stringify(out);
  `);
  let r;
  try { r = JSON.parse(vm.runInNewContext(code, { console, performance }, { timeout: 120000 })); }
  catch (e) { bad('시뮬레이션 실패: ' + e.message); r = null; }
  if (r) {
    r.fail ? bad(r.games + '판 중 ' + r.fail + '판 실패 — ' + r.errs.join(' / '))
           : ok(r.games + '판 모두 정상 종료 (평균 ' + (r.throws / (r.games - r.fail)).toFixed(1) + '회 던짐)');
    const bal = r.wins[0] / (r.wins[0] + r.wins[1]);
    bal > 0.42 && bal < 0.58 ? ok('선공/후공 균형 ' + (bal * 100).toFixed(1) + '%')
                             : bad('승률 치우침 ' + (bal * 100).toFixed(1) + '%');
    Object.values(r.pick0).every(Boolean) ? ok('출발·도착 칸 선택 동작')
                                          : bad('출발·도착 칸 선택 이상: ' + JSON.stringify(r.pick0));
    // 800판 기준 표준오차 약 1.8%p — 실력이 같지 않다면 이 선 아래로 잘 안 내려간다
    r.hardVsNormal > 0.5 ? ok('어려움 > 보통 (' + (r.hardVsNormal * 100).toFixed(1) + '%, 800판)')
                         : bad('어려움이 보통보다 약함 (' + (r.hardVsNormal * 100).toFixed(1) + '%) — 우연일 수 있으니 한 번 더 돌려 보세요');
    r.normalVsEasy > 0.55 ? ok('보통 > 쉬움 (' + (r.normalVsEasy * 100).toFixed(1) + '%, 400판)')
                          : bad('보통이 쉬움보다 충분히 강하지 않음 (' + (r.normalVsEasy * 100).toFixed(1) + '%)');
  }
}

console.log('\n' + (fail ? '❌ ' + fail + '건 실패' : '✅ 전부 통과'));
process.exit(fail ? 1 : 0);
