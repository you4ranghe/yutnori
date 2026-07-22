/* 특별칸(천국·지옥·잉태)이 실제로 어떻게 동작하는지 확인 — node tools/특별칸검사.js */
const vm = require('vm');
const L = require('./lib');

const code = L.ruleCode(`
  function mk(){
    const t=ti=>({name:'T'+ti,icon:TEAM_ICON[ti],color:'#000',deep:'#000',
      players:[{uid:'p'+ti,name:'P'+ti}],pIdx:0,
      pieces:Array.from({length:4},(_,k)=>({id:k,node:null,done:false,hist:[]}))});
    return {gid:'t',ver:1,teams:[t(0),t(1)],cur:0,throwsLeft:0,pending:[],
            phase:'select',sel:0,backdo:true,special:true,winner:null,logs:[]};
  }
  function finish(){let g=0;while(MA){if(++g>40)throw new Error('무한');const cb=MA.cb;MA=null;cb();}}

  /* 그 칸에 정확히 도착하는 (출발칸, 끗수) 를 찾는다 — 지름길까지 고려 */
  function findWay(target){
    for(let from=1;from<=28;from++)
      for(let steps=1;steps<=5;steps++)
        if(computeDest(from,steps,false).dest===target)return {from,steps};
    return null;
  }

  function land(target,enemyAt,waiting){
    const way=findWay(target);
    if(!way)return {오류:'도착 경로 없음'};
    S=mk();
    const T=S.teams[0], E=S.teams[1];
    T.pieces[0].node=way.from;
    T.pieces[0].hist=Array.from({length:Math.max(1,way.from)},(_,i)=>i);
    // 나머지 내 말은 판 밖(대기) 또는 완주 처리
    // 다른 내 말은 대기 상태로 둔다 (게임이 끝나 버리지 않도록)
    if(!waiting)T.pieces[1].node=13;
    if(enemyAt!=null){E.pieces[0].node=enemyAt;E.pieces[0].hist=[0];}
    S.pending=[{name:'x',steps:way.steps}];

    const curBefore=S.cur, enemyOnBoard=E.pieces.filter(p=>typeof p.node==='number').length;
    executeMove({type:'node',node:way.from});
    finish();

    const p=T.pieces[0];
    return {
      경로: way.from+'번에서 '+way.steps+'칸',
      내말위치: p.done?'완주':p.node,
      게임끝: S.winner!==null,
      한번더던짐: S.winner===null&&S.cur===curBefore,
      잡은상대: enemyOnBoard-E.pieces.filter(q=>typeof q.node==='number').length,
      판위내말: T.pieces.filter(q=>typeof q.node==='number').length
    };
  }

  const out={};
  out['골인까지 남은 거리']={'18번(천국)':distToExit(18),'22번(방)':distToExit(22),
                             '19번':distToExit(19),'0번(출발·도착)':distToExit(0)};
  out['천국 — 상대가 방에 없을 때']=land(18,null,false);
  out['천국 — 상대가 방에 있을 때']=land(18,22,false);
  out['지옥']=land(27,null,false);
  out['잉태 — 대기 말 있음']=land(7,null,true);
  out['보통 칸 (비교용)']=land(12,null,false);
  JSON.stringify(out,null,1);
`);
console.log(vm.runInNewContext(code, { console, performance }, { timeout: 20000 }));
