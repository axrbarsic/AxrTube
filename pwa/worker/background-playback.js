// Serialized into the shared player engine as well as tested directly.
// Never swaps sources or runs a background keepalive loop. Android gets one
// short transition-only followup when Chrome immediately re-pauses a resume.
export function createBackgroundPlayback({document,navigator,elements,getMedia,log,now=()=>Date.now(),setTimer=setTimeout,clearTimer=clearTimeout}) {
  let wanted=false,started=false,ticket=null,pendingPause=null,generation=0,lastControlInput=-Infinity,followupTimer=null;
  const androidChrome=/Android/.test(navigator.userAgent||'')&&/Chrome\//.test(navigator.userAgent||'');
  // navigator.standalone is Apple's Home Screen mode indicator. The initial
  // PWA left Audio Session ownership to WebKit; v15 added a playback override.
  // Restore that policy only for installed iOS apps, without changing identity,
  // MediaSession commands, source, or the bounded pause recovery below.
  const browserOwnsAudioSession=navigator.standalone===true;
  function mediaState(value){try{if(navigator.mediaSession)navigator.mediaSession.playbackState=value}catch{}}
  function configure(){try{if(navigator.audioSession){
    if(browserOwnsAudioSession){if(navigator.audioSession.type!=='auto')navigator.audioSession.type='auto';log('audio-session-browser-owned')}
    else{navigator.audioSession.type='playback';log('audio-session-playback')}
  }}catch{log('audio-session-unsupported')}}
  function clearFollowup(){if(followupTimer!==null){clearTimer(followupTimer);followupTimer=null;}}
  function cancel(){clearFollowup();wanted=false;started=false;ticket=null;pendingPause=null;++generation;}
  function userPlay(){clearFollowup();wanted=true;ticket=null;pendingPause=null;lastControlInput=-Infinity;configure();}
  function userPause(){cancel();mediaState('paused');log('explicit-pause');}
  function reset(){cancel();mediaState('none');}
  function stop(){reset();try{if(navigator.audioSession)navigator.audioSession.type='auto'}catch{}}
  function validTransition(media,candidate){return !!candidate&&ticket===candidate&&candidate.media===media&&getMedia()===media&&candidate.generation===generation&&
       wanted&&started&&document.visibilityState==='hidden'&&now()-candidate.at<=2000&&
       !media.ended&&!media.error&&!media.muted&&media.volume!==0&&navigator.audioSession?.state!=='interrupted';}
  function attempt(media,candidate,followup=false){
    log(followup?'background-followup-attempt':'background-resume-attempt');
    const completed=()=>{if(generation===candidate.generation&&ticket===candidate){candidate.accepted=!media.paused;candidate.acceptedAt=now();log(followup?(media.paused?'background-followup-still-paused':'background-followup-accepted'):(media.paused?'background-resume-still-paused':'background-resume-accepted'))}};
    const failed=()=>{if(generation===candidate.generation&&ticket===candidate){ticket=null;log(followup?'background-followup-blocked':'background-resume-blocked');mediaState('paused')}};
    try{Promise.resolve(media.play()).then(completed,failed)}catch{failed()}
  }
  function recover(media){
    const candidate=ticket;
    if(!candidate||candidate.media!==media||candidate.generation!==generation||
       !wanted||!started||document.visibilityState!=='hidden'||now()-candidate.at>2000||
       media.ended||media.error||media.muted||media.volume===0)return false;
    if(navigator.audioSession?.state==='interrupted'){ticket=null;log('background-interrupted');return false;}
    if(candidate.used){
      // Android report v32: first resume accepted, then another platform Pause
      // 31ms later. One delayed followup only, not repeated background polling.
      if(!androidChrome||!candidate.accepted||candidate.followupScheduled||now()-candidate.acceptedAt>250)return false;
      candidate.followupScheduled=true;log('background-followup-scheduled');
      followupTimer=setTimer(()=>{followupTimer=null;if(validTransition(media,candidate)&&media.paused)attempt(media,candidate,true)},120);
      return true;
    }
    candidate.used=true;
    attempt(media,candidate);
    return true;
  }
  document.addEventListener('visibilitychange',()=>{
    if(document.visibilityState!=='hidden'){clearFollowup();ticket=null;pendingPause=null;return;}
    const media=getMedia();
    // iPhone report v15: pause arrived 139/171 ms BEFORE visibilitychange.
    // Only correlate that short transition, never restart an older visible pause.
    if(media.paused){
      const recent=pendingPause&&pendingPause.media===media&&pendingPause.generation===generation&&
        now()-pendingPause.at>=0&&now()-pendingPause.at<=400&&now()-lastControlInput>1000;
      pendingPause=null;
      if(recent){ticket={media,at:now(),generation,used:false};log('background-pause-before-hidden');if(!recover(media))cancel();}
      else cancel();
      return;
    }
    pendingPause=null;
    ticket=wanted&&started&&!media.paused&&!media.ended&&!media.error
      ?{media,at:now(),generation,used:false}:null;
    if(ticket)log('background-transition-armed');
  });
  for(const media of elements){
    media.addEventListener('playing',()=>{if(media!==getMedia())return;wanted=true;started=true;pendingPause=null;lastControlInput=-Infinity;mediaState('playing')});
    // A native control interaction is explicit user intent, including Lock Screen
    // pause (handled separately by the Media Session action in the engine).
    for(const event of ['pointerdown','touchstart','keydown'])media.addEventListener(event,()=>{clearFollowup();lastControlInput=now();ticket=null;pendingPause=null;log('media-control-input')});
    media.addEventListener('pause',()=>{
      if(media!==getMedia())return;
      if(recover(media))return;
      if(document.visibilityState==='visible'&&wanted&&started&&!media.ended&&!media.error&&now()-lastControlInput>1000){
        pendingPause={media,at:now(),generation};ticket=null;mediaState('paused');log('background-pause-pending');
      }else{cancel();mediaState('paused');}
    });
    for(const event of ['ended','error'])media.addEventListener(event,()=>{if(media===getMedia())reset()});
  }
  try{navigator.audioSession?.addEventListener('statechange',()=>{
    log('audio-session-state');
    if(navigator.audioSession.state==='interrupted'){cancel();log('background-interrupted')}
  })}catch{}
  return {userPlay,userPause,reset,stop};
}
