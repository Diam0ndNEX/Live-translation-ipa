import sys, subprocess, collections, re, os, json
from pathlib import Path
def cut(src, start, end_before, out, imports, wrap=None, strip_private=False, widen=(), last_brace=False):
    p=Path(src); L=p.read_text().split("\n")
    idx=[i for i,l in enumerate(L) if l.startswith(start)]; assert len(idx)==1,(start,idx); a=idx[0]
    while a>0 and (L[a-1].lstrip().startswith("///") or L[a-1].startswith("@")): a-=1
    if end_before=="EOF":
        b=len(L)
    elif last_brace:
        b=max(i for i,l in enumerate(L) if l=="}")
    else:
        idx=[i for i,l in enumerate(L) if l.startswith(end_before)]; assert len(idx)==1,(end_before,idx); b=idx[0]
    while L[b-1].strip()=="" or L[b-1].lstrip().startswith("///") or L[b-1].startswith("// MARK") or L[b-1].startswith("@"): b-=1
    block=L[a:b]
    while block and block[-1].strip()=="": block.pop()
    rest=L[:a]
    while rest and rest[-1].strip()=="": rest.pop()
    rest+=[""]+L[b:]
    # names of col-0/4-space private decls kept in rest, used in block?
    if strip_private:
        block=[(l[len("private "):] if l.startswith("private ") else l) for l in block]
    head="\n".join(imports)+"\n\n"
    body="\n".join(block)
    if wrap: body=wrap+" {\n"+body+"\n}"
    Path(out).parent.mkdir(parents=True,exist_ok=True)
    Path(out).write_text(head+body+"\n")
    t="\n".join(rest)
    for old,new in widen:
        assert t.count(old)==1,(old,t.count(old)); t=t.replace(old,new)
    p.write_text(t)
    orig=subprocess.run(["git","show",f"HEAD:{src}"],capture_output=True,text=True).stdout.split("\n")
    n=t.split("\n")+Path(out).read_text().split("\n")
    A,B=collections.Counter(orig),collections.Counter(n)
    print(out, len(block),"lines | extra:",{k:v for k,v in (B-A).items() if k.strip() not in ("","}")},"| missing:",dict(A-B))
