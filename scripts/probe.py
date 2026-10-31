# Quick latency probe: compares provider/settings for transcription over one keep-alive connection.
import base64, http.client, json, subprocess, sys, time
KEY = subprocess.run(["security","find-generic-password","-s","OpenRouter","-a","dictation","-w"],capture_output=True,text=True).stdout.strip()
PROMPT = "Transcribe the speech exactly. Output only the transcript text."
def body(path, provider, reasoning):
    b = base64.b64encode(open(path,"rb").read()).decode()
    d = {"model":"google/gemini-3.1-flash-lite","temperature":0,"max_tokens":400,
         "messages":[{"role":"system","content":PROMPT},{"role":"user","content":[{"type":"input_audio","input_audio":{"data":b,"format":"wav"}}]}],
         "provider":{"order":[provider],"allow_fallbacks":False}}
    if reasoning is not None: d["reasoning"]=reasoning
    return json.dumps(d)
conn = http.client.HTTPSConnection("openrouter.ai")
def call(path, provider, reasoning):
    t=time.perf_counter()
    conn.request("POST","/api/v1/chat/completions",body(path,provider,reasoning),{"Authorization":"Bearer "+KEY,"Content-Type":"application/json"})
    r=conn.getresponse(); data=json.loads(r.read())
    dt=time.perf_counter()-t
    if "choices" not in data: return dt, "ERR "+json.dumps(data)[:200], None
    return dt, data["choices"][0]["message"]["content"], data.get("provider")
clips=sys.argv[1:]
for prov in ["google-vertex/global","google-vertex/global/priority","google-vertex/us","google-ai-studio"]:
  for reas in [{"effort":"none"}]:
    ts=[]
    for i in range(2):
      for c in clips:
        dt,txt,p=call(c,prov,reas); ts.append(dt)
    print(f"{prov:32s} {json.dumps(reas):22s} med={sorted(ts)[len(ts)//2]:.3f} min={min(ts):.3f} max={max(ts):.3f} :: {p} :: {txt!r}")
