# Nasazení killBottleneck na k3s

Postup, jak na vlastním k3s clusteru nasadit:

1. privátní Docker registry na **`registry.jaze.cz`**,
2. aplikaci killBottleneck na **`https://task.jaze.cz`** (s přesměrováním `http` → `https`).

Dokument odpovídá skutečně provedenému nasazení (verze aplikace `v0.76-beta`). Části označené
**netestováno** jsou doporučení, která v clusteru zatím nebyla ověřena.

> **Tajné hodnoty** (heslo registry, registrační klíč) v dokumentu záměrně nejsou. Jsou jen
> v souborech a Kubernetes Secretech, viz [Kde jsou tajné hodnoty](#kde-jsou-tajné-hodnoty).

> **Pracovní adresář a tajné hodnoty.** Všechny příkazy spouštějte z **kořene repozitáře**
> (`/project/killbottleneck`). Veškeré tajné hodnoty (hesla, klíče) se ukládají do složky
> **`secreet-key/`** v kořeni repozitáře, ne do domovského adresáře. Složka má práva 700, soubory
> v ní 600 a je v `.gitignore` i `.dockerignore`, takže se nedostane do gitu ani do image.
> Vytvoření složky: `mkdir -p secreet-key && chmod 700 secreet-key`.

## Obsah

1. [Co se nasazuje a architektura](#1-co-se-nasazuje-a-architektura)
2. [Požadavky](#2-požadavky)
3. [Registry `registry.jaze.cz`](#3-registry-registryjazecz)
4. [Build a push image aplikace](#4-build-a-push-image-aplikace)
5. [Aplikace `task.jaze.cz`](#5-aplikace-taskjazecz)
6. [První spuštění aplikace](#6-první-spuštění-aplikace)
7. [Nastavení AI (Gemini na Vertex AI přes LiteLLM)](#7-nastavení-ai-gemini-na-vertex-ai-přes-litellm)
8. [Provoz: aktualizace, restart, záloha](#8-provoz-aktualizace-restart-záloha)
9. [Smazání z clusteru](#9-smazání-z-clusteru)
10. [Diagnostika problémů](#10-diagnostika-problémů)
11. [Kde jsou tajné hodnoty](#kde-jsou-tajné-hodnoty)

---

## 1. Co se nasazuje a architektura

```
                   Internet
                      │  80/443
              ┌───────▼────────┐
              │ Traefik (k3s)  │  TLS: cert-manager, ClusterIssuer "letsencrypt"
              └───┬────────┬───┘
   registry.jaze.cz│        │task.jaze.cz
        (basicAuth)│        │
        ┌──────────▼─┐   ┌──▼───────────────┐
        │ registry:2 │   │ killbottleneck   │  PocketBase + frontend, port 8090
        │ ns registry│   │ ns killbottleneck│
        └─────┬──────┘   └────────┬─────────┘
        PVC registry-data     PVC kb-data  (/app/pb_data = SQLite + soubory)
              └───────── uzel vps1 (local-path) ─────────┘
```

- **Jeden kontejner** aplikace: PocketBase (API, databáze SQLite, autentizace) servíruje i frontend.
- **Právě jedna replika** (`Recreate`): SQLite nelze sdílet mezi více pody.
- **Data** leží na PVC `kb-data` (`local-path`, vázané na uzel `vps1`, proto `nodeSelector`).
- **Soubory v repozitáři:**
  - `k8s/registry.yaml` – registry,
  - `k8s/killbottleneck.yaml` – aplikace,
  - `k8s/backup.yaml` – denní záloha dat (CronJob),
  - `k8s/pull-backups.sh` – stažení záloh na lokální počítač,
  - `Dockerfile` – build image.

## 2. Požadavky

- Funkční **k3s cluster** s Traefikem (výchozí ingress) a **cert-managerem** s `ClusterIssuer`
  jménem `letsencrypt`.
- Na stroji, ze kterého nasazujete: `kubectl` (s přístupem do clusteru), `docker`,
  `htpasswd` (balík `apache2-utils`), `openssl`, `curl`, `git`.
- **DNS A záznamy** na veřejnou IP uzlu (zde `37.205.8.40`):
  - `registry.jaze.cz`
  - `task.jaze.cz`
- Otevřené porty **80 a 443** na uzlu (HTTP je nutné pro vystavení certifikátu a pro přesměrování).

Ověření prostředí:

```bash
kubectl get nodes -o wide
kubectl get storageclass          # očekává se local-path (default)
kubectl get ingressclass          # očekává se traefik
kubectl get clusterissuer         # očekává se letsencrypt, READY=True
dig +short registry.jaze.cz
dig +short task.jaze.cz
```

## 3. Registry `registry.jaze.cz`

Soukromá registry v namespace `registry`, chráněná HTTP basic auth (Traefik Middleware),
s HTTPS certifikátem a přesměrováním z HTTP.

### 3.1 Namespace a přístupové údaje

```bash
kubectl create namespace registry

mkdir -p secreet-key && chmod 700 secreet-key

# Vygenerovat heslo a uložit ho do souboru jen pro sebe (práva 600).
umask 077
PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
printf 'url: registry.jaze.cz\nuser: kb\npassword: %s\n' "$PW" > secreet-key/registry-jaze-credentials

# Secret pro Traefik basicAuth: klíč "users" musí obsahovat řádek ve formátu htpasswd.
kubectl -n registry create secret generic registry-basic-auth \
  --from-literal=users="$(htpasswd -nbB kb "$PW")"
```

### 3.2 Nasazení

```bash
kubectl apply -f k8s/registry.yaml
kubectl -n registry rollout status deploy/registry --timeout=120s
```

`k8s/registry.yaml` vytvoří: PVC `registry-data` (20 Gi), Deployment `registry` (image
`registry:2`, uzel `vps1`, `REGISTRY_STORAGE_DELETE_ENABLED=true`), Service, dvě Middleware
(`registry-auth`, `redirect-https`) a dva Ingressy (`registry` na `websecure` s TLS a basicAuth,
`registry-http` na `web` s přesměrováním).

### 3.3 Ověření

```bash
kubectl -n registry get certificate,pods        # certifikát READY=True, pod 1/1 Running

PW=$(awk '/password/{print $2}' secreet-key/registry-jaze-credentials)
curl -s -o /dev/null -w "%{http_code}\n" https://registry.jaze.cz/v2/                 # 401 (bez hesla)
curl -s -u "kb:$PW" -w "\n%{http_code}\n" https://registry.jaze.cz/v2/                # {} a 200
curl -s -o /dev/null -w "%{http_code} -> %{redirect_url}\n" http://registry.jaze.cz/v2/   # 301 -> https
```

Certifikát se vystavuje asi minutu po prvním nasazení. Než je `READY=True`, může HTTPS hlásit
chybu certifikátu.

## 4. Build a push image aplikace

```bash
cd /project/killbottleneck            # kořen naklonovaného repozitáře

# Přihlášení do registry. DOCKER_CONFIG přesměruje uložení přihlášení (jinak by docker zapsal
# heslo do ~/.docker/config.json) do složky secreet-key. Heslo se čte ze souboru, ne z historie.
export DOCKER_CONFIG=$PWD/secreet-key/docker
mkdir -p "$DOCKER_CONFIG" && chmod 700 "$DOCKER_CONFIG"
awk '/password/{print $2}' secreet-key/registry-jaze-credentials \
  | docker login registry.jaze.cz -u kb --password-stdin
chmod 600 "$DOCKER_CONFIG/config.json"

# Verze = poslední gitový tag (např. v0.76-beta). Bez --dirty: s neuloženými změnami v repozitáři
# by git describe přidal "-dirty" a tag by pak neodpovídal řádku image: v k8s/killbottleneck.yaml.
VER=$(git describe --tags --abbrev=0)

docker build --network=host --build-arg KB_VERSION=$VER \
  -t registry.jaze.cz/killbottleneck:$VER \
  -t registry.jaze.cz/killbottleneck:latest .

docker push registry.jaze.cz/killbottleneck:$VER
docker push registry.jaze.cz/killbottleneck:latest
```

- `--network=host` jsem použil proto, že se při běžném buildu opakovaně zasekl krok `apk add`
  (viz [diagnostika](#build-se-zasekne-na-apk-add)).
- `KB_VERSION` se předává jako build argument. Bez něj se instance hlásí jako `dev` a nenabízí
  kontrolu aktualizací.
- První build trvá několik minut (sestavuje se frontend, stahuje se PocketBase).

Ověření, že je image v registry:

```bash
curl -s -u "kb:$(awk '/password/{print $2}' secreet-key/registry-jaze-credentials)" \
  https://registry.jaze.cz/v2/killbottleneck/tags/list
# {"name":"killbottleneck","tags":["latest","v0.76-beta"]}
```

## 5. Aplikace `task.jaze.cz`

### 5.1 Namespace a Secrety

```bash
mkdir -p secreet-key && chmod 700 secreet-key

kubectl create namespace killbottleneck

# Pull secret, aby cluster mohl stáhnout image z chráněné registry
kubectl -n killbottleneck create secret docker-registry registry-pull \
  --docker-server=registry.jaze.cz \
  --docker-username=kb \
  --docker-password="$(awk '/password/{print $2}' secreet-key/registry-jaze-credentials)"

# Registrační klíč instance (KB_SETUP_CODE). Bez něj by se mohl zaregistrovat kdokoli.
KEY=$(openssl rand -base64 18 | tr -d '/+=')
kubectl -n killbottleneck create secret generic kb-secrets --from-literal=KB_SETUP_CODE="$KEY"
umask 077; printf '%s' "$KEY" > secreet-key/kb-setup-code

# Superuživatel PocketBase (konzole /_/). Vytvoří se automaticky při prvním startu, viz 6.
# Údaje se předávají souborem, aby heslo nezůstalo v historii shellu ani v seznamu procesů.
umask 077
D=$(mktemp -d)
printf '%s' "postmaster@jaze.cz" > "$D/email"
openssl rand -base64 24 | tr -d '/+=\n' | head -c 24 > "$D/password"
printf 'url: https://task.jaze.cz/_/\nemail: postmaster@jaze.cz\npassword: %s\n' "$(cat $D/password)" \
  > secreet-key/pb-superuser-credentials
kubectl -n killbottleneck create secret generic kb-superuser \
  --from-file=email="$D/email" --from-file=password="$D/password"
rm -rf "$D"
```

### 5.2 Nasazení

Před aplikací zkontrolujte v `k8s/killbottleneck.yaml` řádek `image:` (tag odpovídá buildu).

```bash
kubectl apply -f k8s/killbottleneck.yaml
kubectl -n killbottleneck rollout status deploy/killbottleneck --timeout=180s

# Denní záloha dat (CronJob + PVC), viz sekce 8. Doporučeno nasadit hned:
kubectl apply -f k8s/backup.yaml
kubectl -n killbottleneck get pods,pvc,certificate,ingress
```

`k8s/killbottleneck.yaml` vytvoří:

| Objekt | Účel |
| --- | --- |
| ConfigMap `kb-config` | `TZ=Europe/Prague`, `KB_PORT=8090`, `KB_PUBLIC_URL=https://task.jaze.cz` |
| PVC `kb-data` | 10 Gi, `local-path`, data v `/app/pb_data` |
| Deployment `killbottleneck` | 1 replika, `Recreate`, uzel `vps1`, `imagePullSecrets: registry-pull` |
| Service `killbottleneck` | port 80 → 8090 |
| Middleware `redirect-https` | trvalé přesměrování na https |
| Ingress `killbottleneck` | `task.jaze.cz`, entrypoint `websecure`, TLS certifikát z `letsencrypt` |
| Ingress `killbottleneck-redirect` | `task.jaze.cz`, entrypoint `web`, přesměrování na https |
| initContainer `superuser` | jednorázové založení superuživatele PocketBase (Secret `kb-superuser`) |

Tajné hodnoty (`KB_SETUP_CODE`) se do podu načítají ze Secretu `kb-secrets` přes `envFrom`.
Secret `kb-superuser` musí existovat **před** `kubectl apply`, jinak init kontejner neprojde.

> **Pozor:** PVC používá `local-path` s `volumeBindingMode: WaitForFirstConsumer`. Pod proto
> chvíli zůstane `Pending`, než se naplánuje a PVC naváže. Nejde o chybu. `rollout status` může
> kvůli tomu skončit timeoutem, i když pod za chvíli naběhne.

### 5.3 Ověření

```bash
kubectl -n killbottleneck get pods                       # 1/1 Running
kubectl -n killbottleneck logs deploy/killbottleneck --tail=20

curl -s -o /dev/null -w "%{http_code}\n" https://task.jaze.cz/                      # 200
curl -s -o /dev/null -w "%{http_code} -> %{redirect_url}\n" http://task.jaze.cz/    # 301 -> https://task.jaze.cz/
curl -s https://task.jaze.cz/api/health                                             # {"message":"API is healthy.",...}
```

V clusteru existuje také ingress pro `*.jaze.cz` (namespace `npm`). Konkrétní host `task.jaze.cz`
má v Traefiku přednost, což potvrdilo ověření přesměrování výše.

## 6. První spuštění aplikace

1. Otevřete `https://task.jaze.cz`. Zobrazí se „Set up your instance“.
2. Vyplňte e-mail, heslo a **Activation code**. Je to registrační klíč `KB_SETUP_CODE`:
   ```bash
   cat secreet-key/kb-setup-code
   ```
3. Klikněte na **Create account**. **První účet se stane správcem.**
4. **Superuživatel PocketBase** (konzole `/_/`, potřebný pro nastavení SMTP a nahlížení do
   databáze) se **vytvoří automaticky**. Init kontejner `superuser` v Deploymentu při prvním
   startu spustí `pocketbase superuser create` s údaji ze Secretu `kb-superuser` a zapíše značku
   `/app/pb_data/.superuser-created` na PVC s daty. Při dalších startech značku najde a nic
   nedělá, takže nic nepřepisuje a heslo nemění.
   ```bash
   cat secreet-key/pb-superuser-credentials                                  # url, e-mail a heslo
   kubectl -n killbottleneck logs deploy/killbottleneck -c superuser   # "superuzivatel zalozen" / "preskakuji"
   ```
   - Změna hesla později se dělá v konzoli `/_/` (Secret se po prvním vytvoření nepoužívá).
   - Pokud superuživatele smažete, automaticky se znovu nevytvoří. Smažte značku a restartujte:
     `kubectl -n killbottleneck exec deploy/killbottleneck -- rm /app/pb_data/.superuser-created`
     a `kubectl -n killbottleneck rollout restart deploy/killbottleneck`.
   - Pokud superuživatel s daným e-mailem už existuje (například po obnově ze zálohy),
     `create` ho nepřepíše. Init kontejner to zaloguje (`superuzivatel uz existuje, neprepisuji`)
     a značku zapíše.
   - Při jiné chybě (například heslo kratší než 8 znaků) se v logu objeví `CHYBA: ...`, značka
     se **nezapíše**, aplikace se přesto spustí a pokus se zopakuje při dalším startu. Příkaz
     `pocketbase superuser create` totiž vrací exit code 0 i při chybě, proto init kontejner
     kontroluje jeho výstup. Po opravě Secretu stačí `rollout restart`.

> **Konzole `/_/` je teď dostupná přes internet** (po HTTPS, ale bez dalšího omezení). Viz
> [omezení přístupu k `/_/`](#omezení-přístupu-k-_-nenasazeno-ponecháno-otevřené).

Bez nastaveného SMTP se nepošlou e-maily: pozvánky nových členů ukážou správci dočasné heslo a
upozornění chodí jen do zvonečku v aplikaci. SMTP se nastavuje v konzoli PocketBase
(`/_/` → Settings → Mail settings), ne v proměnných prostředí.

### SMTP (e-maily) přes API

Místo klikání v konzoli `/_/` → Settings → Mail settings lze SMTP nastavit i příkazem. Heslo se čte
ze souboru `secreet-key/smtp-credentials` (formát řádků `host:`, `port:`, `user:`, `password:`),
takže není v historii shellu. Příklad pro `smtp.zoner.com`, port 587, STARTTLS:

```bash
TOK=$(printf '{"identity":"%s","password":"%s"}' \
  "$(awk '/^email/{print $2}' secreet-key/pb-superuser-credentials)" \
  "$(awk '/password/{print $2}' secreet-key/pb-superuser-credentials)" \
  | curl -s -X POST https://task.jaze.cz/api/collections/_superusers/auth-with-password \
      -H 'Content-Type: application/json' --data @- | python3 -I -c "import sys,json;print(json.load(sys.stdin)['token'])")

python3 -I - <<'PY' | curl -s -X PATCH https://task.jaze.cz/api/settings \
  -H "Authorization: $TOK" -H 'Content-Type: application/json; charset=utf-8' --data @-
import json
pw=[l.split(': ',1)[1].strip() for l in open('secreet-key/smtp-credentials') if l.startswith('password')][0]
print(json.dumps({
 "smtp":{"enabled":True,"host":"smtp.zoner.com","port":587,"username":"postmaster@jaze.cz",
         "password":pw,"authMethod":"PLAIN","tls":False,"localName":""},
 "meta":{"appName":"killBottleneck","appURL":"https://task.jaze.cz","senderName":"killBottleneck",
         "senderAddress":"postmaster@jaze.cz","accentColor":"#1055c9","hideControls":False}}))
PY

# zkušební e-mail (204 = odesláno)
curl -s -X POST https://task.jaze.cz/api/settings/test/email -H "Authorization: $TOK" \
  -H 'Content-Type: application/json' \
  -d '{"email":"postmaster@jaze.cz","template":"verification","collection":"_superusers"}' -w "%{http_code}\n"
```

- `"tls": false` na portu 587 znamená STARTTLS (při `true` by se použilo implicitní TLS, typicky port 465).
- `meta.appURL` musí být veřejná adresa, jinak by odkazy v e-mailech (reset hesla, ověření) mířily na
  výchozí `http://localhost:8090`. `meta` se v PATCH nahrazuje celé, proto se posílají všechna pole.
- Nastavení je v databázi (`pb_data`), takže je součástí zálohy a přežije restart.

## 7. Nastavení AI (Gemini na Vertex AI přes LiteLLM)

AI je ve výchozím stavu vypnutá. Používá se **Gemini na Vertex AI** (`gemini-2.5-flash`, region
`europe-west4`, data zůstávají v EU). killBottleneck umí přes poskytovatele `openai` jen **statický
klíč**, ale Vertex AI chce OAuth token s hodinovou platností. Mezi ně proto v clusteru běží
**LiteLLM proxy**, která drží klíč servisního účtu a navenek vydává OpenAI-kompatibilní API
se statickým klíčem. Proxy je dostupná jen uvnitř clusteru (bez ingressu).

```
killBottleneck ──(http, statický klíč)──▶ litellm.killbottleneck.svc:4000 ──(klíč servisního účtu)──▶ Vertex AI
```

### 7.1 Google Cloud: servisní účet a klíč

Projekt `test-skola-jaze` musí mít zapnuté `aiplatform.googleapis.com` a fakturaci. Pro killBottleneck
se zakládá **vlastní** servisní účet jen s rolí `aiplatform.user` (volání modelů). Účty a klíče jiných
aplikací se nepoužívají, aby šly oprávnění zrušit odděleně.

```bash
P=test-skola-jaze
SA=killbottleneck-vertex

gcloud services list --enabled --project=$P --format="value(config.name)" | grep aiplatform
gcloud iam service-accounts create $SA --project=$P --display-name="killBottleneck Vertex AI (LiteLLM)"
gcloud projects add-iam-policy-binding $P \
  --member="serviceAccount:$SA@$P.iam.gserviceaccount.com" --role="roles/aiplatform.user" --condition=None

# klíč servisního účtu rovnou do secreet-key (nikdy do gitu)
umask 077
gcloud iam service-accounts keys create secreet-key/vertex-sa.json \
  --iam-account=$SA@$P.iam.gserviceaccount.com --project=$P

# statický klíč proxy, který bude používat killBottleneck
printf 'sk-kb-%s' "$(openssl rand -hex 24)" > secreet-key/litellm-master-key
```

Ověření modelu v regionu (odpověď nesmí být useknutá, viz poznámka o „přemýšlení“ níže):

```bash
T=$(gcloud auth print-access-token)
curl -s -X POST -H "Authorization: Bearer $T" -H "Content-Type: application/json" \
  "https://europe-west4-aiplatform.googleapis.com/v1/projects/$P/locations/europe-west4/publishers/google/models/gemini-2.5-flash:generateContent" \
  -d '{"contents":[{"role":"user","parts":[{"text":"Odpověz jedním slovem: ahoj"}]}]}'
```

### 7.2 LiteLLM proxy v clusteru

```bash
kubectl -n killbottleneck create secret generic litellm-secrets \
  --from-file=LITELLM_MASTER_KEY=secreet-key/litellm-master-key \
  --from-file=vertex-sa.json=secreet-key/vertex-sa.json

kubectl apply -f k8s/litellm.yaml
kubectl -n killbottleneck rollout status deploy/litellm --timeout=240s
```

`k8s/litellm.yaml` obsahuje ConfigMap s konfigurací modelu, Deployment a Service. Obraz
`ghcr.io/berriai/litellm` je připnutý na **digest** (`main-stable` ke dni nasazení), takže se
nezmění beze změny manifestu. Model je v konfiguraci `vertex_ai/gemini-2.5-flash` s
`reasoning_effort: disable`.

**Proč se vypíná „přemýšlení“:** Gemini 2.5 Flash má uvažování ve výchozím stavu zapnuté a
spotřebuje tím limit tokenů. Při zkoušce s limitem 50 tokenů šlo 45 na uvažování a odpověď měla
jediné písmeno. Dokumentace killBottlenecku před takovým chováním varuje. S vypnutým uvažováním
odpověď dojde celá a bez tokenů navíc.

Ověření proxy (přes port-forward, klíč ze souboru):

```bash
kubectl -n killbottleneck port-forward svc/litellm 14000:4000 &
curl -s -o /dev/null -w "%{http_code}\n" localhost:14000/v1/models        # 401 bez klíče
printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' \
  "$(cat secreet-key/litellm-master-key)" \
  | curl -s -K - localhost:14000/v1/chat/completions \
      -d '{"model":"gemini-2.5-flash","max_tokens":50,"messages":[{"role":"user","content":"Řekni ahoj."}]}'
kill %1
```

### 7.3 Napojení killBottlenecku

Adresa a model jsou v ConfigMapu `kb-config` (`k8s/killbottleneck.yaml`), klíč v Secretu `kb-secrets`.
Obecné `KB_AI_*` platí pro asistenta, souhrny i hůlku, `KB_VISION_*` pro čtení obrázků.

| Proměnná | Hodnota |
| --- | --- |
| `KB_AI_PROVIDER` | `openai` |
| `KB_AI_URL` | `http://litellm.killbottleneck.svc.cluster.local:4000/v1` |
| `KB_AI_MODEL` | `gemini-2.5-flash` |
| `KB_AI_TOKEN` | klíč proxy (Secret `kb-secrets`) |
| `KB_VISION_PROVIDER`, `KB_VISION_URL`, `KB_VISION_MODEL`, `KB_VISION_TOKEN` | stejné hodnoty pro obrázky |

Secret `kb-secrets` se při změně aktualizuje celý, takže musí znovu obsahovat i registrační klíč:

```bash
kubectl -n killbottleneck create secret generic kb-secrets \
  --from-file=KB_SETUP_CODE=secreet-key/kb-setup-code \
  --from-file=KB_AI_TOKEN=secreet-key/litellm-master-key \
  --from-file=KB_VISION_TOKEN=secreet-key/litellm-master-key \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f k8s/killbottleneck.yaml
kubectl -n killbottleneck rollout restart deploy/killbottleneck
```

Ověření: `curl -s https://task.jaze.cz/api/kb/config` musí vrátit `"ai_enabled": true` a v
`ai_modes` mimo jiné `chat_panel` a `chat_image`. Po přihlášení se v horní liště zobrazí tlačítko
asistenta.

Poznámky:

- **Hlasovky:** vyžadují přepis řeči ve tvaru OpenAI (`/audio/transcriptions`), který tahle
  konfigurace nenabízí. Mikrofon se proto neukáže. Přepis lze doplnit samostatně (`KB_TRANSCRIBE_*`).
- **Soukromí:** data map a rozhovorů odcházejí do Vertex AI v projektu `test-skola-jaze`
  (region `europe-west4`).
- **Náklady:** volání Vertex AI se účtuje na projekt. Hodinový strop `KB_AI_MAX_PER_HOUR` (60) platí
  na osobu, týdenní kvótu lze nastavit v Administraci → AI kredity.
- **Rotace klíčů:** klíč proxy změníte novým souborem v `secreet-key/`, aktualizací obou Secretů
  (`litellm-secrets`, `kb-secrets`) a restartem obou Deploymentů. Klíč servisního účtu se ruší
  příkazem `gcloud iam service-accounts keys delete KEY_ID --iam-account=... --project=...`.

## 8. Provoz: aktualizace, restart, záloha

### Aktualizace aplikace (nová verze)

```bash
cd /project/killbottleneck
export DOCKER_CONFIG=$PWD/secreet-key/docker     # přihlášení k registry z kroku 4
git pull
VER=$(git describe --tags --abbrev=0)

docker build --network=host --build-arg KB_VERSION=$VER \
  -t registry.jaze.cz/killbottleneck:$VER -t registry.jaze.cz/killbottleneck:latest .
docker push registry.jaze.cz/killbottleneck:$VER
docker push registry.jaze.cz/killbottleneck:latest

# '*=' nastaví image všem kontejnerům, včetně init kontejneru "superuser"
kubectl -n killbottleneck set image deploy/killbottleneck \
  '*=registry.jaze.cz/killbottleneck:'$VER
kubectl -n killbottleneck rollout status deploy/killbottleneck --timeout=180s
```

Aktualizujte také řádek `image:` v `k8s/killbottleneck.yaml`, aby manifest odpovídal stavu
v clusteru. Aplikace i serverová logika jsou „zapečené“ v image, takže pouhý restart nestačí
k nasazení nového kódu.

### Restart deploymentu

```bash
# Restart bez změny image (načte znovu ConfigMap/Secret, vyvolá nový pod)
kubectl -n killbottleneck rollout restart deploy/killbottleneck
kubectl -n killbottleneck rollout status deploy/killbottleneck

# Stav, události a logy
kubectl -n killbottleneck get pods -o wide
kubectl -n killbottleneck describe pod -l app=killbottleneck
kubectl -n killbottleneck logs deploy/killbottleneck -f
```

Totéž pro registry: `kubectl -n registry rollout restart deploy/registry`.

Dočasné vypnutí bez mazání dat (PVC zůstane):

```bash
kubectl -n killbottleneck scale deploy/killbottleneck --replicas=0
kubectl -n killbottleneck scale deploy/killbottleneck --replicas=1
```

> Změny v ConfigMapu `kb-config` se do běžícího podu nepropíšou samy. Po každé změně udělejte
> `rollout restart`. Dokumentace aplikace uvádí, že se konfigurace po změně vždy přestavuje,
> ne jen restartuje. Zda server čte proměnné za běhu, nebo při buildu, jsem neověřoval.
> Po změně proměnné vždy zkontrolujte, že se projevila.

### Záloha dat

Denní záloha běží jako CronJob `kb-backup` (`k8s/backup.yaml`):

- **Plán:** každý den ve **3:00** (časové pásmo `Europe/Prague`), archivy starší **14 dní** se mažou
  (`KEEP_DAYS`).
- **Obsah:** konzistentní kopie SQLite databází (`data.db`, `auxiliary.db`) příkazem
  `sqlite3 .backup` (bezpečné i za běhu aplikace) a složka `storage/` s nahranými soubory,
  zabalené do `kb-backup-<datum>.tgz`.
- **Uložení:** PVC `kb-backups` (5 Gi, uzel `vps1`). Je to na stejném uzlu jako data, takže to
  chrání před chybou aplikace nebo smazáním dat, ne před ztrátou disku. Proto existuje i kopie
  na váš počítač.

```bash
# nasazení
kubectl apply -f k8s/backup.yaml

# ruční spuštění zálohy mimo plán a kontrola
kubectl -n killbottleneck create job --from=cronjob/kb-backup kb-backup-manual
kubectl -n killbottleneck logs job/kb-backup-manual
kubectl -n killbottleneck delete job kb-backup-manual

# stav plánu a posledních běhů
kubectl -n killbottleneck get cronjob,job
```

**Kopie na váš počítač** (do složky `custom-backup/` v kořeni repozitáře, ta je v `.gitignore`):

```bash
./k8s/pull-backups.sh                  # stáhne jen archivy, které lokálně ještě nejsou
./k8s/pull-backups.sh /jiná/složka     # volitelně jiná cílová složka
```

Skript spustí krátkodobý pomocný pod s připojeným PVC `kb-backups`, archivy stáhne přes
`kubectl exec` a pod smaže. Spouštějte ho pravidelně (například z cronu na svém počítači,
`0 9 * * * /cesta/k8s/pull-backups.sh`), protože lokální složka se sama neaktualizuje.
Lokální archivy se nemažou, o jejich retenci rozhodujete vy.

**Ověření zálohy** (provedeno): archiv obsahuje `data.db` a `auxiliary.db`, obě databáze
prošly `PRAGMA integrity_check` s výsledkem `ok`.

```bash
mkdir /tmp/kb-check && tar xzf custom-backup/kb-backup-*.tgz -C /tmp/kb-check
python3 -I -c "import sqlite3; print(sqlite3.connect('/tmp/kb-check/data.db').execute('PRAGMA integrity_check').fetchone())"
rm -rf /tmp/kb-check
```

**Obnova** (vyzkoušeno na testovací instanci: smazaný uživatel se po obnově vrátil):

```bash
# 1) zastavit aplikaci
kubectl -n killbottleneck scale deploy/killbottleneck --replicas=0
kubectl -n killbottleneck wait --for=delete pod -l app=killbottleneck --timeout=60s

# 2) pomocný pod s PVC kb-data a kb-backups: SMAŽE obsah /data a rozbalí nejnovější archiv
#    (pro starší stav nahraďte "ls -t ... | head -1" jménem konkrétního souboru)
kubectl -n killbottleneck run kb-restore --image=busybox --restart=Never --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"vps1"},"containers":[{"name":"kb-restore","image":"busybox","command":["sh","-c","set -e; A=$(ls -t /backups/kb-backup-*.tgz | head -1); echo archiv: $A; find /data -mindepth 1 -delete; tar xzf $A -C /data; ls -la /data"],"volumeMounts":[{"name":"d","mountPath":"/data"},{"name":"b","mountPath":"/backups","readOnly":true}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"kb-data"}},{"name":"b","persistentVolumeClaim":{"claimName":"kb-backups"}}]}}'
kubectl -n killbottleneck wait --for=jsonpath='{.status.phase}'=Succeeded pod/kb-restore --timeout=120s
kubectl -n killbottleneck logs kb-restore             # musí vypsat obnovené soubory (data.db, auxiliary.db)
kubectl -n killbottleneck delete pod kb-restore

# 3) znovu spustit aplikaci
kubectl -n killbottleneck scale deploy/killbottleneck --replicas=1
kubectl -n killbottleneck rollout status deploy/killbottleneck
```

Obnova přepíše **všechna** současná data. Před ní si případně ručně stáhněte aktuální stav
(`./k8s/pull-backups.sh` po ruční záloze). Archiv neobsahuje značku `.superuser-created`, takže
init kontejner po obnově proběhne znovu a díky `superuzivatel uz existuje` nic nepřepíše.

> Záloha bere obsah `pb_data` při běžném provozu. Zálohy neobsahují secrety z Kubernetesu
> (`kb-secrets`, `registry-pull`) ani hesla registry, ty držte odděleně.

### Omezení přístupu k `/_/` (nenasazeno, ponecháno otevřené)

Konzole PocketBase `/_/` je podle rozhodnutí **ponechána otevřená** z internetu (po HTTPS, chráněná
přihlášením superuživatele). Pokud to později budete chtít změnit, jsou dvě možnosti (netestováno):

- **Port-forward** místo veřejného přístupu: v Ingressu cestu zablokovat a konzoli otevírat přes
  ```bash
  kubectl -n killbottleneck port-forward svc/killbottleneck 8090:80
  # pak http://localhost:8090/_/
  ```
- **Omezení podle IP** přes Traefik Middleware `ipAllowList` a samostatný Ingress pro cestu `/_`
  (nahraďte `X.X.X.X/32` svou veřejnou IP):
  ```yaml
  apiVersion: traefik.io/v1alpha1
  kind: Middleware
  metadata: { name: admin-ip, namespace: killbottleneck }
  spec:
    ipAllowList:
      sourceRange: ["X.X.X.X/32"]
  ```
  Middleware se pak připojí anotací
  `traefik.ingress.kubernetes.io/router.middlewares: killbottleneck-admin-ip@kubernetescrd`
  na Ingress s `path: /_`. Chování za Traefikem a zdrojové IP je potřeba ověřit.

## 9. Smazání z clusteru

> **Pozor na data.** Storage class `local-path` má `reclaimPolicy: Delete`. Smazání PVC nebo
> celého namespace **nevratně smaže data** (databázi, nahrané soubory, obrazy v registry).
> Nejdřív proveďte [zálohu](#záloha-dat).

### Jen aplikace, data zachovat

```bash
kubectl -n killbottleneck delete deploy/killbottleneck svc/killbottleneck \
  ingress/killbottleneck ingress/killbottleneck-redirect middleware/redirect-https
# PVC kb-data, kb-backups, ConfigMap, Secrety i CronJob zálohy zůstávají; opětovné nasazení:
# kubectl apply -f k8s/killbottleneck.yaml
```

### Celá aplikace včetně dat

```bash
# NEJDŘÍV zálohy: dokončené pody CronJobu stále odkazují na PVC kb-data a smazání PVC
# by jinak zůstalo viset ve stavu Terminating.
kubectl delete -f k8s/backup.yaml                # CronJob a PVC kb-backups (smaže i zálohy v clusteru)
kubectl delete -f k8s/killbottleneck.yaml        # smaže i PVC kb-data
kubectl delete namespace killbottleneck          # Secrety (registry-pull, kb-secrets, kb-superuser)
rm -f secreet-key/kb-setup-code secreet-key/pb-superuser-credentials
```

### Registry včetně uložených image

```bash
kubectl delete -f k8s/registry.yaml              # smaže i PVC registry-data
kubectl delete namespace registry
rm -f secreet-key/registry-jaze-credentials
DOCKER_CONFIG=$PWD/secreet-key/docker docker logout registry.jaze.cz
rm -rf secreet-key/docker
```

Po smazání zkontrolujte: `kubectl get ns`, `kubectl get pv`. Případné zbylé certifikáty
a Secrety `*-tls` se mažou spolu s namespace.

## 10. Diagnostika problémů

### Build se zasekne na `apk add`

**Příznak:** `docker build` stojí na kroku `RUN apk add --no-cache ca-certificates unzip tzdata
&& wget ...`, poslední řádek logu je `fetch https://dl-cdn.alpinelinux.org/.../APKINDEX`
a nic se nehýbe (minuty až desítky minut). Přitom `docker run --rm alpine:3.20 apk update`
projde za pár sekund.

**Řešení:** spustit build se sítí hostitele a build sledovat:

```bash
docker build --network=host --progress=plain --build-arg KB_VERSION=$VER \
  -t registry.jaze.cz/killbottleneck:$VER . 2>&1 | tee build.log
```

Zaseknutý build ukončete podle PID (`pgrep -x docker-buildx`, pak `kill PID`). Příkaz
`pkill -f` může zabít i vlastní shell, protože vzor najde jeho příkazovou řádku.

### Pod zůstává `Pending`

```bash
kubectl -n killbottleneck describe pod -l app=killbottleneck | sed -n '/^Events:/,$p'
kubectl -n killbottleneck get pvc
```

Při `WaitForFirstConsumer` se PVC naváže až s naplánováním podu. Pokud pod nenaběhne ani
po několika minutách, zkontrolujte události (nedostatek zdrojů, `nodeSelector`, uzel `NotReady`).
Uzel `vps1` musí být `Ready`, protože PVC je vázané na něj.

### `ImagePullBackOff` / `ErrImagePull`

```bash
kubectl -n killbottleneck describe pod -l app=killbottleneck | grep -A5 -i "failed to pull"
kubectl -n killbottleneck get secret registry-pull
curl -s -u "kb:$(awk '/password/{print $2}' secreet-key/registry-jaze-credentials)" \
  https://registry.jaze.cz/v2/killbottleneck/tags/list
```

Možné příčiny: tag v `image:` neexistuje v registry, chybí nebo je špatné heslo v Secretu
`registry-pull` (znovu ho vytvořte), neplatný certifikát registry.

### `rollout status` skončí timeoutem, ale pod chvíli poté běží

Viz poznámka výše: čekání na navázání PVC. Zkontrolujte `kubectl -n killbottleneck get pods`.

### Certifikát není `READY`

```bash
kubectl -n killbottleneck get certificate,certificaterequest,order,challenge
kubectl -n killbottleneck describe certificate killbottleneck-tls
```

Nejčastější příčiny: DNS záznam ještě neukazuje na uzel, je blokovaný port 80, nebo chybí
`ClusterIssuer` `letsencrypt`. Challenge HTTP-01 potřebuje, aby šla na `http://<doména>/.well-known/...`
cesta ven.

### `http://` nepřesměrovává

```bash
curl -sI http://task.jaze.cz/ | head -3        # očekává se 301 a Location: https://...
kubectl -n killbottleneck get ingress,middleware
```

Ingress `killbottleneck-redirect` musí být na entrypointu `web` s anotací
`router.middlewares: killbottleneck-redirect-https@kubernetescrd` (formát
`<namespace>-<název middleware>@kubernetescrd`).

### Init kontejner nebo pod: `ImagePullBackOff`, v události `not found`

```bash
kubectl -n killbottleneck describe pod -l app=killbottleneck | sed -n '/^Events:/,$p'
curl -s -u "kb:$(awk '/password/{print $2}' secreet-key/registry-jaze-credentials)" \
  https://registry.jaze.cz/v2/killbottleneck/tags/list
```

`not found` znamená, že tag z řádku `image:` (u init i hlavního kontejneru) v registry není.
Typicky po nasazení do **nové (prázdné) registry** nebo když byl image nahrán pod jiným tagem,
například `v0.76-beta-dirty` (`git describe --dirty` ho přidá, jsou-li v repozitáři změněné
soubory). Řešení: nahrát image pod očekávaným tagem, nebo ho přetagovat bez nového buildu:

```bash
export DOCKER_CONFIG=$PWD/secreet-key/docker
docker tag registry.jaze.cz/killbottleneck:v0.76-beta-dirty registry.jaze.cz/killbottleneck:v0.76-beta
docker push registry.jaze.cz/killbottleneck:v0.76-beta
kubectl -n killbottleneck delete pod -l app=killbottleneck     # urychlí nový pokus o stažení
```

### `docker push` hlásí `unauthorized` nebo `tag does not exist`

- `unauthorized`: znovu `docker login registry.jaze.cz`.
- `tag does not exist`: image se nepodařilo sestavit (build byl přerušen), takže se nemá co
  nahrát. Zkontrolujte `docker images registry.jaze.cz/killbottleneck` a build zopakujte.

## Kde jsou tajné hodnoty

| Hodnota | Kde je | Poznámka |
| --- | --- | --- |
| Heslo registry (uživatel `kb`) | `secreet-key/registry-jaze-credentials` (práva 600) | v clusteru jako Secret `registry-basic-auth` (htpasswd) a `registry-pull` |
| Registrační klíč instance | `secreet-key/kb-setup-code` (práva 600) | v clusteru jako Secret `kb-secrets` (`KB_SETUP_CODE`) |
| Klíč servisního účtu Google Cloud | `secreet-key/vertex-sa.json` (práva 600) | v clusteru jako Secret `litellm-secrets` |
| Klíč LiteLLM proxy | `secreet-key/litellm-master-key` (práva 600) | Secrety `litellm-secrets` a `kb-secrets` (`KB_AI_TOKEN`, `KB_VISION_TOKEN`) |
| Přihlášení dockeru k registry | `secreet-key/docker/config.json` (práva 600, `DOCKER_CONFIG`) | jen lokálně, obsahuje heslo registry v base64 |
| Superuživatel PocketBase (`/_/`) | `secreet-key/pb-superuser-credentials` (práva 600) | v clusteru jako Secret `kb-superuser`; používá se jen při prvním založení |

Do gitu nikdy nepatří soubory s hesly ani zálohy dat. Heslo zadané na příkazové řádce
(například `superuser upsert EMAIL HESLO`) zůstává v historii shellu, po použití ho změňte
a řádek z historie smažte.
