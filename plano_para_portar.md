# Design por partes: groupOperationGuard, legitimacySignalInjector, humanEntropy + fechamento

> Este documento é um plano de implementação futura — nada aqui foi implementado
> ainda. Quando for retomar, siga as partes em ordem; cada uma é independente,
> revisável e testável isoladamente, sem depender das seguintes.

## Contexto

`topologyThrottler`/`banRecovery` (os 2 módulos de alto risco mais críticos) já foram
implementados e commitados (`15f170b`). Esta rodada cobre os 3 módulos restantes de
alto risco que fazem sentido para uma conta única (sem fleet), na ordem que o
usuário pediu — "por partes": cada parte abaixo é independente, revisável e
testável isoladamente, sem depender das seguintes.

Fora de escopo desta rodada (confirmado com o usuário — só conta única por agora):

- **`reputationVoucher.ts`** — exige uma segunda conta WhatsApp real ("voucher")
  enviando mensagens pra uma terceira pessoa. Não faz sentido pra uma única sessão.
- **`instanceCoordinator.ts`** / **`fleetEventStore.ts`** — coordenação entre
  processos via arquivo compartilhado / MySQL. Só tem valor com múltiplas
  instâncias do bot rodando; num único nó BEAM isso seria substituível por uma ETS
  table ou GenServer local, o que hoje seria trabalho sem benefício real.

Também investiguei (lendo `/home/coelhorb/elixir_ana/amarula` diretamente, não só o
upstream) se `deviceFingerprint.ts`/`sessionFingerprint.ts`/`stealthConnect.ts`/
`proxyRotator.ts`/`credsSnapshot.ts` já são cobertos pelo Amarula:

| Área | Veredito |
|---|---|
| Stealth connect (mark-online, browser tuple) | **Amarula já cobre** — `:mark_online_on_connect` (config) + `Connection.mark_online?/1`; `:browser` cobre a tupla OS/client/version. Nada a portar aqui. |
| Device fingerprint (OS version, device model, build, MCC/MNC) | Parcial — `:version`/`:browser`/`:country_code` são configuráveis; o resto está fixo em literais dentro de `AuthUtils.create_user_agent/1`/`create_device_props/1`. Corrigir isso é mudança **no Amarula**, não no antiban. |
| Jitter de keepalive/timing de sessão | Amarula não cobre — intervalo fixo, sem variação por sessão. Mudança **no Amarula**. |
| Proxy (SOCKS5/HTTP/HTTPS) | Amarula não cobre — zero código de proxy no `WebSocketClient`. Mudança **no Amarula**. |
| Backup/rotação de `creds` | Amarula não cobre — `Storage` é get/put/delete simples, sem versionamento. **Isso dá pra fazer dentro do antiban** como um adapter que empacota qualquer `Amarula.Storage` existente (ver Parte 4c). |

Ou seja: dos 5 itens "precisa verificar" da auditoria anterior, 1 já está resolvido
pelo Amarula, 3 exigem PR no Amarula (fora do escopo deste pacote), e 1 (backup de
creds) é implementável aqui mesmo.

## Parte 1 — `AmarulaAntiban.Core.GroupOperationGuard`

Novo arquivo `lib/amarula_antiban/core/group_operation_guard.ex` + teste dedicado.

Fonte real lida (`/tmp/baileys-antiban/src/groupOperationGuard.ts`): rate limit de
**janela fixa** (não deslizante) por `{operação, chave}`, onde chave é o JID do
grupo (ou o `subject` no caso de `create`). Operações: `:add | :remove | :create |
:invite`.

**Config** (própria do módulo, `nested(options, :group_operation_guard)`):
```
enabled: false
limits: %{
  add:    %{max: 3,  window_ms: 600_000},
  remove: %{max: 5,  window_ms: 600_000},
  create: %{max: 2,  window_ms: 600_000},
  invite: %{max: 10, window_ms: 600_000}
}
```

**Struct:** `%{config:, windows: %{"op:key" => %{count:, reset_at:}}}`.

**`check(guard, op, key, now_ms)`** — porta `check()` 1:1:
- `window_key = "#{op}:#{key}"`.
- Sem entrada OU `now_ms > entry.reset_at` → reseta: `count: 1, reset_at: now_ms + limit.window_ms`, retorna `{:allow, guard}` (a primeira chamada da janela nunca é contra o próprio limite — igual ao JS).
- `entry.count >= limit.max` → `{:deny, reason, retry_after_sec, guard}` sem mutar o contador; `reason` no formato `"Too many #{op} attempts. WhatsApp rate-limits group operations — wait #{ceil(retry_after_sec/60)} min before trying again."`.
- Caso contrário → incrementa `count`, `{:allow, guard}`.

**`reset(guard, op, key)`** — remove a entrada, permitindo reuso imediato.

**`classify_error(reason)`** — pattern match Elixir-idiomático (não regex/substring
como no JS) mapeando erros já conhecidos do Amarula para
`:reachout_restricted | :rate_overlimit | :group_locked | :invite_expired | nil`.
**Verificar durante a implementação** contra o retorno real de
`Amarula.Group.*` (não explorado nesta rodada) — se Amarula já devolve erros
estruturados (átomos/tuplas) em vez de strings, o pattern match deve casar
nesse formato, não em substring de mensagem como o JS.

`extractPrivacyBlock` (parsing de node binário WA cru pra extrair código de convite
de um bloqueio de privacidade) **não é portado** — é detalhe de protocolo que já é
responsabilidade do Amarula, não do antiban.

**Integração — API pública nova, fora do pipeline `on_send`:**
Operações de grupo (`Amarula.Group.add_participants/3` etc.) não passam pelo
`on_send`/`on_recv` do `Amarula.Plugin` (esse pipeline é só pra mensagens). Portanto:

- `state.ex`: novo campo `group_operation_guard: Core.GroupOperationGuard.t()`.
- `session.ex`: nova função pública `check_group_operation(server, op, key)` ::
  `{:allow, decision} | {:deny, decision}` que chama `Core.GroupOperationGuard.check/4`
  puro e persiste o resultado (mesmo padrão de `record_463_error/1`/`record_ban_event/2`
  — não passa pela cadeia `decide/4`, que é exclusiva de mensagens).
- `AmarulaAntiban.check_group_operation/3` na fachada (`lib/amarula_antiban.ex`),
  delegando pro `Session` via `with_session/2`.
- O host chama isso manualmente antes de `Amarula.Group.*`:
  ```elixir
  case AmarulaAntiban.check_group_operation(session, :add, group_jid) do
    {:allow, _} -> Amarula.Group.add_participants(conn, group_jid, participants)
    {:deny, decision} -> {:error, decision.detail}
  end
  ```
- `snapshot.ex`: `export/1`/`restore/2` próprios (padrão `ContactGraph`) já que
  `windows` é um mapa aninhado com chaves string dinâmicas — não dá pra usar o
  helper genérico direto.

## Parte 2 — `AmarulaAntiban.Core.LegitimacySignals` (só injeção de erro de digitação)

Novo arquivo `lib/amarula_antiban/core/legitimacy_signals.ex` + teste dedicado.

Fonte real lida (`/tmp/baileys-antiban/src/legitimacySignalInjector.ts`): das 3
funções do módulo (`shouldInjectTypo`, `shouldInjectReadGap`, `getTypingPauses`),
**só `shouldInjectTypo` é chamada em algum lugar do `wrapper.ts` upstream** — as
outras duas são API morta, nunca invocada em produção mesmo no JS. Portamos só o
que upstream realmente usa; não faz sentido portar dead code.

**Config:**
```
enabled: false
typo_probability: 0.025
typo_correct_min_ms: 500
typo_correct_max_ms: 2000
```

**Struct:** `%{config:, rand_fun:, stats: %{typos_injected:, corrections_generated:}}`
(mesmo padrão de injeção de `rand_fun` usado em `ContentVariator`/`ReplyRatio`).

**`maybe_inject_typo(injector, text)`** — porta 1:1 a lógica de `shouldInjectTypo`:
1. `byte_size(text) <= 10` ou `!enabled` → `{:none, injector}`.
2. Roll de probabilidade: `rand_fun.() >= typo_probability` → `{:none, injector}`.
3. Contém URL (`~r/https?:\/\/|www\./i`) → `{:none, injector}`.
4. Palavras elegíveis: split por espaço, `byte_size >= 3`, não começa com `@`, não é
   só dígitos.
5. Sem palavra elegível → `{:none, injector}`.
6. Sorteia uma palavra, substitui **um** caractere por um vizinho no teclado QWERTY
   (mapa de adjacência de 26 letras, hardcoded como `@qwerty_adjacent` — mesma tabela
   do JS), preservando maiúscula/minúscula.
7. Sem letra adjacente disponível na palavra sorteada → `{:none, injector}`.
8. Substitui a **primeira ocorrência** da palavra original pela versão com erro
   (`String.replace(text, word, typo_word, global: false)`).
9. `correction_delay_ms` = inteiro uniforme em `[500, 2000]`.
10. `correction_text` = a mensagem inteira de novo se `byte_size(text) < 30`, senão
    `"*#{word}"` (convenção de correção do WhatsApp).
11. Incrementa `stats.typos_injected`/`corrections_generated`, retorna
    `{:typo, %{typo_text:, correction_delay_ms:, correction_text:}, injector}`.

**Integração — decisão fica no core puro, execução fica no `Plugin`:**
- `Decision` (`lib/amarula_antiban/decision.ex`) ganha um campo novo `typo: map() | nil`.
- `session.ex`: `decide_rate`'s branch `:allow` já tem acesso ao `content` — chama
  `Core.LegitimacySignals.maybe_inject_typo/2` ali e inclui o resultado em `%Decision{}`
  (mesmo lugar onde `presence_plan` já é montado).
- `plugin.ex`'s `send_step`: quando `decision.typo` não é nil, precisa enviar o texto
  com erro primeiro e a correção depois — dois sends reais, como o `wrapper.ts`
  original faz (`sendMessage` do texto errado, espera `correction_delay_ms`, manda a
  correção).

  **Ponto a verificar antes de implementar**: hoje `ctx.message` em `send_step` é
  tratado como uma estrutura tipo-protobuf (`message_content/1` usa `field/2` pra
  extrair `conversation`/`extendedTextMessage.text`/captions). Preciso confirmar,
  lendo o contrato real de `Amarula.Plugin.on_send` (`ctx` de saída, não de entrada —
  os dois podem ter formatos diferentes), se dá pra: (a) mutar só o texto de
  `ctx.message` antes de `{:cont, ctx}` pra que o Amarula envie a versão com erro, e
  (b) disparar o envio da correção como uma chamada **separada e explícita** a
  `Amarula.send_text/3` depois do sleep (fora do pipeline, do jeito que
  `execute_presence_step/4` já chama `Amarula.send_chatstate/3` diretamente). Se
  `ctx.message` para envio for só uma string simples (não uma struct rica), a
  mutação fica trivial; se for uma struct de conteúdo completa, a mutação do campo
  de texto precisa espelhar a mesma extração que `message_content/1` já faz.
- `state.ex`/`snapshot.ex`: campo `legitimacy_signals` simples (sem coleções
  aninhadas — só `stats`), usa o helper genérico `mutable_data`/`restore_struct`.

`shouldInjectReadGap`/`getTypingPauses` ficam documentados em `docs/PARITY.md` como
"não portado — dead code também no upstream", não como uma lacuna real.

## Parte 3 — `HumanEntropy` (escopo reduzido: typing + presence toggle)

Fonte real lida (`/tmp/baileys-antiban/src/humanEntropy.ts`): é o único dos 3 que
roda **fora** do fluxo de envio — um timer recursivo próprio (`setTimeout` que se
re-agenda, não `setInterval`), disparando ações de 2 em 2–6 horas contra contatos
que já mandaram mensagem primeiro. É uma mudança de arquitetura real: os outros
módulos deste port inteiro são "pure core decidido dentro de `decide/4`" — este é o
primeiro caso de um **processo de fundo independente por sessão**.

**Escopo reduzido pra esta parte**: só `performTypingPresence` (digitar e parar) e
`performPresenceToggle` (ficar online/offline por um tempo) — as duas únicas ações
que usam chamadas já confirmadas no port (`Amarula.send_chatstate/3`,
`Amarula.set_presence/2`, ambas já usadas em `plugin.ex`). **`performReadReceipt`
fica de fora desta parte**: precisa de uma lista de mensagens não lidas com o
message ID/key real, e `Session.record_incoming/2,3` hoje descarta o `id` do `ctx`
(`Plugin.receive_step` já recebe `%{id: _id, ...}` e ignora). Portar isso exigiria
(1) estender `record_incoming` pra aceitar o id, (2) confirmar qual função do
Amarula marca mensagens como lidas (não verificado nesta rodada). Trato como uma
Parte 3b separada, só depois que isso for confirmado.

**`AmarulaAntiban.Core.HumanEntropy`** (pure core, novo arquivo):
```
Config: enabled: false, min_interval_ms: 7_200_000, max_interval_ms: 21_600_000,
        max_recent_contacts: 30, typing_probability: 0.3, typing_min_ms: 3_000,
        typing_max_ms: 8_000, presence_toggle_probability: 0.15,
        presence_toggle_min_ms: 30_000, presence_toggle_max_ms: 120_000
Struct: %{config:, rand_fun:, recent_contacts: [%{jid:, last_message_at:}], stats: %{...}}
```
- `track_incoming(entropy, jid, now_ms)` — dedup por jid, atualiza timestamp,
  corta pra `max_recent_contacts` mantendo os mais recentes (mesma lógica do JS).
- `next_delay_ms(entropy)` — inteiro uniforme em `[min_interval_ms, max_interval_ms]`.
- `roll_cycle(entropy)` — decide independentemente (dois rolls de probabilidade,
  não mutuamente exclusivos) se dispara `:typing` (sorteia um contato) e/ou
  `:presence_toggle`; devolve uma lista de ações com durações sorteadas, igual ao
  `executeCycle` do JS (`Promise.allSettled` vira, aqui, "as duas podem sair juntas
  num único ciclo").

**Camada OTP — novo ramo de supervisão, análogo a `EventBridge`/`PersistenceWriter`:**
- `AmarulaAntiban.HumanEntropyWorker` — GenServer por sessão, registrado num novo
  `AmarulaAntiban.HumanEntropyRegistry`, supervisionado por um novo
  `AmarulaAntiban.HumanEntropySupervisor` (`DynamicSupervisor`), ambos adicionados à
  árvore em `application.ex` no mesmo padrão dos pares já existentes.
- Ao iniciar (ou reagendar), pega `now_fun`/estado de `recent_contacts` via
  `Session` (nova função `Session.human_entropy_snapshot/1` ou reaproveitar
  `Session.stats/1`), roda `Core.HumanEntropy.roll_cycle/1` puro, e executa as ações
  resultantes chamando `Amarula.whereis(profile)` + `Amarula.send_chatstate/3`/
  `Amarula.set_presence/2` diretamente — mesmo padrão de `best_effort/2` já usado em
  `plugin.ex` pra tolerar conexão indisponível.
- `Session` ganha `record_incoming` já disparando `Core.HumanEntropy.track_incoming/3`
  (ao lado do que já é feito pra `reply_ratio`/`contact_graph`/`topology_throttler`).
- Iniciado por `Plugin.attach/2` (não pelo `SessionSupervisor` sozinho), porque só
  faz sentido existir quando há uma conexão Amarula real pra falar com — mesmo
  raciocínio de por que `EventBridge` existe.
- `state.ex`/`snapshot.ex`: campo `human_entropy` com `recent_contacts` (lista
  simples, sem chaves dinâmicas) — helper genérico serve.

Esta parte é a mais arquiteturalmente nova das três; se preferir, dá pra adiar e
fazer só Partes 1+2+4 primeiro.

## Parte 4 — Fechamento

**4a. Teste de integração via `Amarula.Testing`** — hoje não existe nenhum teste
exercitando `Amarula.new(...) |> AmarulaAntiban.attach() |> Amarula.connect()` de
ponta a ponta contra o sandbox oficial do Amarula. Adicionar um teste em
`test/amarula_antiban/` cobrindo: attach → envio real através do `on_send` →
decisão → efeito de presença → evento voltando pelo `event_bridge`.

**4b. Atualizar a dependência `../amarula`** — está ~13 commits atrás do
`/tmp/amarula-upstream` (nenhum deles muda `Plugin`/`Storage`/eventos, mas inclui
correções reais de handshake/timeout).

**4c. `AmarulaAntiban.Storage.Backup`** (opcional, portável sem tocar o Amarula) —
um adapter que implementa `Amarula.Storage` envolvendo QUALQUER outro adapter
existente, mantendo as últimas N cópias do namespace `:creds` antes de sobrescrever
(atomic write + retenção, no mesmo espírito de `credsSnapshot.ts`). Como
`Amarula.Storage` já é um behaviour plugável pelo consumidor, isso não exige
mudança no Amarula — só um novo módulo aqui. É opcional porque resolve um problema
de robustez operacional, não de anti-ban propriamente dito.

**4d. `docs/PARITY.md`** — nova seção cobrindo Partes 1–3 (mesmo padrão de W3/W4),
mais uma nota explícita: `deviceFingerprint`/`sessionFingerprint`/`proxyRotator`
exigem mudança no Amarula (não no antiban) — registrar como itens de upstream, não
como gap deste pacote. `reputationVoucher`/`instanceCoordinator`/`fleetEventStore`
documentados como fora de escopo (exigem fleet/multi-conta).

## Verificação

- Cada parte segue o padrão já estabelecido: `mix test`, `mix compile
  --warnings-as-errors`, `mix credo --strict`, `mix dialyzer` limpos antes de
  prosseguir pra próxima (linha de base atual: 226 testes, 0 warnings, 0 issues).
- Parte 1: teste cobrindo janela fixa (reset exato no boundary), `retry_after_sec`,
  `reset/2`, round-trip de snapshot com `windows` populado.
- Parte 2: teste da fórmula de score/probabilidade com `rand_fun` determinístico
  (mesmo estilo dos testes existentes de `ContentVariator`/`ReplyRatio`), teste de
  integração em `session_test.exs` confirmando que `decision.typo` aparece quando
  o roll de probabilidade força isso.
- Parte 3: teste do `Core.HumanEntropy` puro (rolls determinísticos via `rand_fun`),
  mais um teste do `HumanEntropyWorker` usando um clock injetado (mesmo padrão do
  teste de `SessionLifecycle`/`timelock_resume` em `session_test.exs`, sem
  `Process.sleep` real).
- Parte 4a é o teste que finalmente teria fechado a lacuna "nunca testamos o attach
  real" apontada na primeira auditoria.
