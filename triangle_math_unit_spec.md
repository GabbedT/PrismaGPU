# Specifica e prompt di implementazione: `triangle_math_unit.sv`

## 1. Obiettivo

Implementare l'unità aritmetica condivisa del triangle setup del Raster Engine di ZenithSoC. Il rasterizzatore è diretto e usa scanline. Questa unità esegue soltanto i calcoli aritmetici richiesti dal controllo del triangle setup: reciproco dell'area, slope e coordinata iniziale dei bordi, gradienti degli attributi e valore degli attributi al punto di riferimento.

Non inserire in questo modulo fetch DDR, ordinamento dei vertici, bounding box, scissor, rasterizzazione, texture cache, z-test o blending. Il chiamante prepara i vertici/operandi, sceglie il comando e salva i risultati.

Il modulo deve usare microprogrammi costanti, una sola FSM di esecuzione, un moltiplicatore condiviso, un'unità di reciproco condivisa e una sola unità add/sub. Moltiplicatore e reciproco sono presumibilmente multiciclo: definirne qui soltanto le istanze e il contratto di interfaccia, lasciando l'implementazione in file separati.

## 2. Decisioni consolidate e formati fissati da questa specifica

Decisioni già prese:

- Gli ingressi del chiamante sono operandi diretti e restano stabili durante tutta la transazione; non copiarli in un banco di registri interni.
- Le sole destinazioni delle microistruzioni sono `T0`, `T1`, `T2`, `OUT`.
- `T2` conserva il primo prodotto nei gradienti. `OUT` viene scritto soltanto con il risultato finale.
- Il chiamante salva `1/D`, `gx`, `gy`, `sx` e li ripresenta come ingressi quando servono.
- `gx` e `gy` sono due comandi separati, con un risultato per comando.
- I programmi sono `localparam` costanti selezionati da `command_reg` e `micro_pc`; non vengono copiati in un command register contenente l'intera sequenza.
- Le coordinate originali sono signed: X 19 bit, Y 18 bit, entrambe F8. Non usare i vertici arrotondati della bounding box per gradienti o slope.

Questa revisione sostituisce i risultati generici a 96 bit con un profilo compatto per la FPGA: gradienti 32 bit, slope 32 bit, X iniziale 24 bit e riferimenti attributo 44 bit, per viewport massimo 640×480. I prodotti intermedi restano completi. Il limite sui gradienti e la gestione di overflow sono espliciti nella sezione 4.1.1; modificare i formati soltanto insieme a interfacce, analisi delle larghezze e controlli numerici.

Convenzione: `S(W,F)` indica complemento a due signed di W bit, F frazionari; `U(W,F)` indica unsigned. Il valore reale di un intero codificato N è `N * 2^(-F)`. In questa notazione non c'è ambiguità sul conteggio del bit di segno.

| Dato | Formato | Note |
| --- | --- | --- |
| Coordinate x e xref | `S(19,8)` | ABI GE e centro pixel |
| Coordinate y e yref | `S(18,8)` | ABI GE e centro pixel |
| Differenza X | `S(19,8)` | Dominio clippato 0..640 |
| Differenza Y | `S(18,8)` | Dominio clippato 0..480 |
| Attributi a0/a1/a2 | `S(32,16)` | Contratto comune di questa versione |
| Differenza di attributi | `S(33,16)` | Nessun troncamento |
| D sul bus GE | `S(38,16)` | Determinante signed esatto delle coordinate trasmesse |
| D al reciproco | `S(38,16)` | Derivato dal dominio clippato |
| gx, gy | `S(32,16)` | Gradienti compatti, range [-32768,32768) |
| sx | `S(32,12)` | Slope con range circa ±524288 |
| xinitial | `S(24,12)` | Coordinate bordo con range circa ±2048 |
| aref | `S(44,16)` | Margine per riferimento fuori triangolo |
| Mantissa reciproca | `U(32,30)` | Mantissa positiva, segno separato |
| Esponente reciproco | signed 8 bit | Potenza di due relativa al valore reale |
| Reciproco completo | 41 bit packed | Segno 1 + esponente 8 + mantissa 32 |
| T0/T1/T2 e payload OUT | 88 bit | Prodotti interi completi e margine per somme |

Z del GE è `U(17,16)` (Q1.16, z/w): zero-estenderlo a 32 bit, poi interpretarlo come `S(32,16)`. RGB444 intero (0..15) viene zero-esteso a 32 bit prima di `channel << 16`; non scalarlo a 0..255. UV e gli eventuali u/w, v/w, 1/w devono essere convertiti a questo contratto soltanto se rientrano nel suo intervallo: non assumere una conversione sempre priva di perdita. Se serve altro range/precisione, aggiornare i parametri e rifare le prove di larghezza prima dell'RTL.

## 3. Interfaccia esterna

Tutti i comandi usano lo stesso insieme di porte. I soli operandi significativi per il comando richiesto sono quelli elencati nella sezione 9; gli altri non devono influenzare il risultato.

| Porta | Direzione | Bit / tipo | Significato |
| --- | --- | --- | --- |
| `clk_i` | input | 1 | Clock |
| `rst_n_i` | input | 1 | Reset attivo basso; proposta: sincrono, da uniformare al repository |
| `command_valid_i` | input | 1 | Richiesta valida |
| `command_ready_o` | output | 1 | Accettazione consentita solo in IDLE |
| `command` | input | `command_t`, 3 | Uno dei sei comandi |
| `x0_i,x1_i,x2_i` | input | ciascuno signed 19 | Coordinate X dei vertici originali |
| `y0_i,y1_i,y2_i` | input | ciascuno signed 18 | Coordinate Y dei vertici originali |
| `a0_i,a1_i,a2_i` | input | ciascuno signed 32 | Un attributo dei vertici originali |
| `xref_i` | input | signed 19 | Centro X del primo pixel della bounding box |
| `yref_i` | input | signed 18 | Centro Y o centro prima riga del bordo |
| `area_i` | input | signed 38 | D con segno e 16 bit frazionari |
| `recip_area_i` | input | `reciprocal_t`, 41 | 1/D salvato dal chiamante |
| `sx_i` | input | signed 32 | Slope S(32,12) salvato dal chiamante |
| `gx_i,gy_i` | input | ciascuno signed 32 | Gradienti S(32,16) salvati dal chiamante |
| `valid_o` | output | 1 | Risposta finale disponibile |
| `ready_i` | input | 1 | Il chiamante accetta la risposta |
| `result_o` | output | 88 | Payload del registro OUT |
| `status_o` | output | `status_t`, 2 | OK, divisione per zero, overflow o comando invalido |
| `busy_o` | output | 1 | Stato diverso da IDLE, inclusa risposta in attesa |

Per i comandi dei bordi, rimappare le porte: V0 è l'estremo superiore `(xa,ya)`, V1 quello inferiore `(xb,yb)`. Per EDGE_INIT, `yref` porta il centro della prima scanline attiva `jstart+0.5`, non necessariamente il riferimento globale della bounding box. Questo evita porte duplicate per xa/ya/xb/yb/ystart.

Protocollo:

1. La richiesta è accettata sul fronte con `command_valid_i && command_ready_o`.
2. Registrare soltanto il comando, azzerare micro_pc e inizializzare lo stato di risposta. Non registrare tutti gli operandi.
3. Il chiamante mantiene gli ingressi operando invariati dall'accettazione fino al fronte con `out_valid && out_ready`. Dopo l'accettazione può deassertare `cmd_valid`; `cmd` non serve più perché è registrato.
4. Non accettare altri comandi durante l'esecuzione o una risposta pendente.
5. `out_data` e `out_status` restano stabili sotto backpressure.
6. Il reset annulla la transazione; resettare anche le unità esterne per impedire risposte stale.

CALC_GRAD_X/Y restituiscono S(32,16) in out_data[31:0]; CALC_SLOPE restituisce S(32,12) in out_data[31:0]; CALC_EDGE_INIT restituisce S(24,12) in out_data[23:0]; CALC_ATTR_REF restituisce S(44,16) in out_data[43:0]. Per tutti questi risultati i bit superiori sono estensione del segno. Per INV_AREA, `out_data[40:0]` contiene `reciprocal_t`, il resto è zero. Il chiamante conosce il comando emesso: non serve un secondo tag. In caso di errore usare payload zero; non consegnare un valore troncato come risultato valido.

## 4. Architettura e dimensionamento

Registri dati visibili al microsequencer: `T0`, `T1`, `T2`, `OUT`, tutti di 88 bit. I temporanei conservano gli interi codificati alla precisione prevista per ogni passo; non sono tutti interpretati con lo stesso punto binario. Le unità multiciclo possono avere accumulatori e registri di pipeline propri: non contarli come assenti nel bilancio di area.

Registri di controllo: command_reg, micro_pc (3 bit per programmi fino a 8 istruzioni), FSM state, status. Finché micro_pc non avanza, la microistruzione corrente e il suo dst rimangono stabili; non serve registrare un'altra copia dell'intera microistruzione.

### 4.1 Limiti delle operazioni

| Operazione | Larghezza completa | Frazionari |
| --- | --- | --- |
| Differenza X / Y | 19 / 18 | 8 |
| Prodotto dx×dy per D | 37 | 16 |
| Differenza dei prodotti per D | 38 | 16 |
| Differenza attributi | 33 | 16 |
| Differenza attributo × dy / dx | 51 / 52 | 24 |
| Numeratore gradiente X / Y | 52 / 53 | 24 |
| Numeratore × mantissa reciproca estesa | fino a 86 | 54 |
| Gradiente 32 × dx / dy | 51 / 50 | 24 |
| Somma dei prodotti di riferimento, inclusa a0 | fino a 53 | 24 |
| Slope 32 × dy18 | 50 | 20 |
| Somma per xinitial | fino a 51 | 20 |
| Prodotto completo della unità 54×33 | 87 | Dipende dal passo |

88 bit coprono prodotti e somme delle sequenze ammesse. Non significa che qualsiasi operazione arbitraria tra due registri da 88 bit possa essere eseguita senza overflow: i microprogrammi vincolano il range di ogni operando. Prima di restringere un temporaneo all'ingresso di una unità verificare che i bit scartati siano estensioni del segno.

### 4.1.1 Contratto compatto e limiti funzionali

Il profilo è dimensionato per **640×480 massimo**, con vertici già clippati dal GE: 0<=x<=viewport_width<=640 e 0<=y<=viewport_height<=480. Il limite superiore geometrico è inclusivo; gli indici dei pixel sono 0..width-1 e 0..height-1. I centri di riferimento devono essere nel viewport. Le porte coordinate sono X S(19,8), Y S(18,8); validarle contro il viewport. I formati signed da soli non garantiscono il clipping. Il top non deve clampare singoli vertici: sarebbe un clipping geometrico scorretto.

Gradienti gx/gy: S(32,16); slope sx: S(32,12); X iniziale: S(24,12); riferimento aref: S(44,16). Gli attributi originali rimangono nativi nel chiamante; S(32,16) è soltanto il bus operando comune. Non espandere permanentemente i canali RGB nel registro del triangolo.

Anche a 640×480 i gradienti dei triangoli quasi degeneri possono superare S(32,16). Restituire STATUS_OVERFLOW se il valore arrotondato non è rappresentabile: il setup scarta il triangolo con SETUP_MATH_ERROR. Non saturare né troncare per nascondere il limite. Un fallback per questi triangoli non è incluso.

Per aref, con gradienti rappresentabili, le differenze sono limitate a 640 e 480 pixel. Il modulo del valore reale è minore di 32768*(640+480)+32768, cioè 36,732,928, inferiore a 2^26. S(44,16) ha 28 bit interi incluso segno e range circa ±2^27: copre l'estrapolazione e conserva margine. Gli accumulatori dello scanline stage mantengono lo stesso formato sino alla conversione del frammento coperto.

Per il bordo, dy minimo non nullo è 1/256: |sx|<=640*256=163840, coperto da S(32,12). xinitial al centro di una riga attiva è tra gli estremi X geometrici, quindi S(24,12) copre il range con margine per l'approssimazione. Verificare gli errori del reciproco e le conversioni ai limiti. EDGE_INIT con operandi non conformi al segmento può comunque andare in overflow: non eliminare il controllo.

Slope e xinitial hanno risoluzione 2^-12; gradienti e aref 2^-16. L'errore di quantizzazione dello slope, prima degli altri errori numerici, è al massimo 0.5*2^-12 per riga con nearest rounding: su 480 righe è circa 0.059 pixel. Questo non garantisce coverage top-left esatto; i correttivi del rasterizzatore rimangono necessari. Per i gradienti, su 640 passi X la sola quantizzazione contribuisce al massimo circa 0.00489 unità attributo; valutare anche la scala effettiva di Z e gli errori del reciproco.

### 4.2 Moltiplicatore esterno

Proposta di contratto: ingresso A signed 54 bit, ingresso B signed 33 bit, risultato signed 87 bit completo. Il B da 33 bit serve sia per differenze signed a 33 bit sia per mantisse unsigned a 32 bit zero-estese. Estendere il risultato a 88 bit prima del writeback.

Non istanziare un moltiplicatore 88×88. Ogni MUL dei programmi deve poter essere mappata sui due ingressi ammessi. Nei gradienti Y, scambiare l'ordine delle sorgenti del prodotto per tenere la differenza XY sul B quando opportuno.

Definire il moltiplicatore nel file separato `triangle_multiplier.sv`. `triangle_math_unit.sv` deve contenerne soltanto l'istanza. Il modulo esterno deve avere due implementazioni interne selezionate a elaborazione tramite la macro `_VIVADO_`:

```systemverilog
`ifdef _VIVADO_
    // Implementazione tramite IP moltiplicatore Vivado con pipeline multiciclo.
`else
    // Implementazione comportamentale tramite operatore *.
`endif
```

Nel ramo `_VIVADO_`, usare un IP moltiplicatore Vivado e configurare pipeline e latenza per il target Nexys A7 a **100 MHz**, periodo **10 ns**. Calcolare la configurazione migliore mediante confronto di configurazioni supportate, sintesi e timing dopo implementazione: scegliere una soluzione che soddisfi il timing del percorso completo e bilanci consumo di DSP/LUT/FF e latenza. Non assegnare un numero di stadi arbitrario né dichiarare una configurazione ottima soltanto dalla frequenza nominale. Riportare configurazione scelta, latenza, risorse e slack; senza tool/report disponibili, lasciare la scelta esplicitamente da verificare.

Verificare le larghezze e la signedness supportate dall'IP. Se il prodotto 54×33 non è supportato direttamente, implementare nel file esterno la decomposizione in prodotti parziali con IP Vivado e relativa accumulazione, conservando il risultato signed completo a 87 bit. Confrontare le alternative pertinenti senza duplicare l'intero datapath nella triangle_math_unit. Fornire il necessario script/configurazione riproducibile per generare l'IP; non affidarsi a un IP configurato manualmente e non tracciato.

Nel ramo senza `VIVADO`, usare una semplice moltiplicazione signed con operatore `*`, con dimensionamento esplicito del risultato a 87 bit. Non implementare un secondo algoritmo a prodotti parziali in questo ramo. Mantenere comunque il wrapper di handshake: acquisire gli operandi alla richiesta, produrre una sola risposta per richiesta e mantenere il prodotto stabile sotto backpressure. Questo ramo serve anche alla simulazione senza IP Vivado; non richiede il medesimo numero di cicli del ramo IP né una garanzia di timing a 100 MHz.

Entrambi i rami devono rispettare la stessa interfaccia req/resp e produrre esattamente lo stesso prodotto intero. La macro seleziona soltanto l'implementazione interna, non il contratto esterno. Gestire valid e reset dell'IP e trattenere la risposta in un registro del wrapper se l'IP non supporta backpressure. La FSM chiamante deve attendere il handshake della risposta, senza assumere una latenza fissa.

```systemverilog
triangle_multiplier u_multiplier (
    .clk(clk), .rst_n(rst_n),
    .req_valid(mul_req_valid), .req_ready(mul_req_ready),
    .operand_a(mul_a), .operand_b(mul_b),
    .resp_valid(mul_resp_valid), .resp_ready(mul_resp_ready),
    .product(mul_product)
);
```

È un contratto proposto, non l'API verificata di un file già esistente. Nell'implementazione leggere e adattare eventuali moduli già presenti.

### 4.3 Unità esterna di reciproco

RECIP calcola `1/d`, non una divisione generica tra due operandi. Porta denominatore signed 38 bit e un selettore typed per 8 oppure 16 bit frazionari. Slope passa dy esteso a 38 bit; INV_AREA passa D ristretto a 38 bit dopo verifica dei bit di segno.

La normalizzazione deve operare sulla magnitudine a 39 bit, calcolata dopo estensione del segno, per evitare overflow nell'assoluto del minimo signed. Non restringere D al formato del vecchio divisore del GE senza analisi.

Sul handshake RECIP registra denominatore signed a 38 bit e formato frazionario. Lo stato NORMALIZE calcola magnitudine, normalizzazione ed esponente dai registri, separando il mux dell'operando dalla normalizzazione. Per denominatori nonzero aggiunge un ciclo; zero produce subito la risposta di divisione per zero. Denominatore e formato esterni possono cambiare dopo l'accettazione. Registro di stato, transizioni combinatorie e registri dati sono separati; reset cancella la richiesta e la risposta resta stabile sotto backpressure.

Rappresentazione:

`abs(d_real) = m * 2^e`, con `1 <= m < 2`.

`1/d_real ≈ (-1)^negative * mantissa * 2^(-30) * 2^exponent`, con `exponent = -e`.

Il fattore frazionario del denominatore va incluso nella normalizzazione: per D, un raw integer vale `raw_D * 2^-16`, per dy `raw_dy * 2^-8`. Non calcolare il reciproco del raw integer e usarlo come reciproco del valore reale.

Per il reciproco, partire dall'implementazione già presente in `perspective_divide/`: leggere il modulo di reciproco, la LUT e le dipendenze effettive. È consentito copiarli in nuovi file dedicati al Raster Engine e modificarli come base di `triangle_reciprocal.sv`, evitando di alterare il comportamento del divisore usato dal GE. Verificare il percorso e i nomi reali nel repository, senza presumerli da questa specifica.

Adattare larghezze, normalizzazione, gestione del segno, esponente, precisione LUT, numero di iterazioni, arrotondamenti, divisione per zero e handshake al contratto qui definito. Non limitarsi ad allargare le porte mantenendo costanti, slice o scale del modulo originale. Riutilizzare le dipendenze immutate se compatibili; copiare o adattare quelle che richiedono un formato diverso.

Conservare l'approccio LUT + Newton–Raphson come punto di partenza. Proposta interna: mantissa di lavoro `U(34,32)`, prodotti completi 68 bit, sottrazioni allineate almeno 69 bit, conversione finale a `U(32,30)`. Definire e verificare precisione LUT, iterazioni, arrotondamenti e errore del reciproco: 32 bit di uscita non garantiscono da soli 32 bit accurati.

```systemverilog
triangle_reciprocal u_reciprocal (
    .clk(clk), .rst_n(rst_n),
    .req_valid(recip_req_valid), .req_ready(recip_req_ready),
    .denominator(recip_denominator), .den_format(recip_den_format),
    .resp_valid(recip_resp_valid), .resp_ready(recip_resp_ready),
    .result(recip_result), .div_zero(recip_div_zero)
);
```

Tutte le risposte delle unità esterne devono restare stabili finché `resp_ready` è basso. La latenza può variare; una sola operazione è outstanding.

### 4.4 Add/sub

Usare una sola unità combinatoria signed a 88 bit, controllata dall'opcode. Per rilevare overflow signed usare un bit aggiuntivo nell'espressione di controllo (somma/sottrazione estesa a 89 bit), senza introdurre un quinto registro dati. Prima dell'operazione allineare i punti binari mediante estensioni e shift costanti previsti dal passo.

Se la sintesi mostra che questo add/sub è critico, valutare una realizzazione multiciclo in un modulo separato; non inserire pipeline casualmente e non dichiarare raggiunti area o timing senza sintesi.

## 5. Tipi RTL

Definire tipi condivisi in un package o nell'header coerente col repository. Tutti i campi della microistruzione devono avere un typedef, incluso `last`.

```systemverilog
typedef enum logic [2:0] {
    CALC_INV_AREA, CALC_SLOPE, CALC_EDGE_INIT,
    CALC_GRAD_X, CALC_GRAD_Y, CALC_ATTR_REF
} command_t;

typedef enum logic [1:0] {
    ADD, SUB, MUL, RECIP
} uop_opcode_t;

typedef enum logic [4:0] {
    X0, X1, X2, Y0, Y1, Y2,
    A0, A1, A2, XREF, YREF,
    AREA, RECIP_AREA, SX, GX, GY,
    T0, T1, T2, UNUSED
} operand_sel_t;

typedef enum logic [1:0] {
    T0, T1, T2, OUT
} destination_t;

typedef enum logic {
    MORE_OPS, LAST_OP
} last_op_t;

typedef struct packed {
    uop_opcode_t op;
    operand_sel_t src_a;
    operand_sel_t src_b;
    destination_t dst;
    last_op_t last;
} microinstruction_t;

typedef struct packed {
    logic negative;
    logic signed [7:0] exponent;
    logic [31:0] mantissa;
} reciprocal_t;

typedef enum logic {
    DEN_F8, DEN_F16
} denominator_format_t;

typedef enum logic [1:0] {
    STATUS_OK, STATUS_DIV_ZERO, STATUS_OVERFLOW, STATUS_INVALID_CMD
} status_t;

typedef enum logic [2:0] {
    IDLE, VALIDATE, ISSUE, WAIT_RESULT, CONVERT, ROUND, WRITEBACK, RESPONSE
} state_t;
```

La microistruzione ha 15 bit: opcode 2 + sorgenti 5+5 + destinazione 2 + last 1. RECIP ignora src_b, che deve essere `SRC_UNUSED`. Non aggiungere MOV, NOP, branch o indirizzi di salto finché non servono a un programma reale.

## 6. Multiplexer delle unità

Ogni ingresso di ogni unità ha un mux davanti. Le selezioni sono segnali di tipo `operand_sel_t`, derivati dalla microistruzione corrente, non numeri magici.

- Add/sub: due mux a 88 bit, con allineamento specifico del passo.
- Moltiplicatore: un mux A a 54 bit e un mux B a 33 bit; scegliere soltanto le sorgenti realmente usate su quel lato.
- Reciproco: un mux denominatore a 38 bit, con selezione del formato `denominator_format_t`.
- Writeback: mux del risultato della unità attiva verso una delle quattro destinazioni typed.

Usare case combinatori completi con default deterministici. `SRC_UNUSED` non deve avviare una operazione binaria valida. Evitare un unico crossbar universale tra tutte le sorgenti e tutte le unità: lo spazio di codifica comune non obbliga a collegare ogni sorgente fisicamente a ogni mux.

`OUT` non è una sorgente. Un registro temporaneo può essere sorgente e destinazione nella stessa microistruzione: si leggono i vecchi dati, si scrive al termine.

## 7. FSM di esecuzione

| Stato | Comportamento | Transizione |
| --- | --- | --- |
| IDLE | cmd_ready=1; attesa richiesta | Su handshake: registra comando e vai a VALIDATE; comando invalido: RESPONSE con errore |
| VALIDATE | Controlla microistruzione e rappresentabilità signed degli operandi dopo gli aggiornamenti di PC/temporanei | Registra issue_error e vai a ISSUE, senza lanciare o acquisire operazioni |
| ISSUE | Usa issue_error registrato e presenta la richiesta alla unità scelta | Errore: RESPONSE; MUL/RECIP: su req handshake vai a WAIT_RESULT; ADD/SUB: registra risultato e overflow, poi vai a CONVERT soltanto se serve cambiare scala, altrimenti WRITEBACK |
| WAIT_RESULT | Non rilanciare la richiesta, non avanzare micro_pc | Su resp handshake registra risultato e status; vai a CONVERT soltanto se serve cambiare scala, altrimenti WRITEBACK |
| CONVERT | Esegue lo shift del risultato aritmetico registrato e valuta guard/sticky | Registra risultato signed a 88 bit, incremento di rounding ed errore di conversione, poi vai a ROUND |
| ROUND | Applica l'incremento nearest, ties-to-even al valore registrato | Registra risultato signed a 89 bit, poi vai a WRITEBACK |
| WRITEBACK | Controlla overflow e formato del risultato convertito, poi scrive dst | Errore: RESPONSE; LAST: RESPONSE; altrimenti incrementa micro_pc e vai a VALIDATE |
| RESPONSE | out_valid=1, risposta stabile, cmd_ready=0 | Su out_ready vai a IDLE |

Il risultato aritmetico signed a 88 bit, dopo l'eventuale applicazione del segno del reciproco, e lo status della unità attiva vengono registrati prima di CONVERT. CONVERT registra il valore dopo lo shift, la decisione di incremento nearest, ties-to-even e l'errore di conversione. ROUND applica l'incremento in un ciclo distinto e conserva il bit aggiuntivo del risultato signed a 89 bit per il controllo overflow in WRITEBACK. CONVERT e ROUND sono eseguiti soltanto per la microistruzione finale di SLOPE, EDGE_INIT, GRAD_X/Y e ATTR_REF. Le altre microistruzioni e INV_AREA conservano il risultato completo, con estensione del segno a 89 bit, e passano direttamente a WRITEBACK: nessun arrotondamento viene eliminato, perché per queste operazioni shift e incremento sono zero. Lo status aritmetico e i controlli di rappresentabilità restano attivi. L’errore di conversione viene azzerato per ogni risultato che salta i due stati, impedendo di riusare quello della conversione precedente. Per MUL/RECIP `resp_ready` si attiva soltanto in WAIT_RESULT e il risultato viene acquisito quando `resp_valid` è alto. Il micro_pc rimane fermo sino al writeback, quindi conserva opcode, selezioni e destinazione durante la latenza. Le sorgenti esterne devono restare stabili fino alla risposta; sotto backpressure OUT e status restano stabili.

VALIDATE aggiunge un clock per microistruzione e separa i controlli di ampiezza dai segnali di richiesta e dagli enable dei registri aritmetici/conversione. Nello stesso ciclo registra shift_count signed a 9 bit, output_width e conversion_needed; la sottrazione dell'esponente non alimenta quindi shift, rounding e riduzione di overflow nello stesso ciclo. Non cambia formati, arrotondamenti o backpressure. Eseguire `make -C tb/verilator test-math` per verificare i sei programmi con riferimento numerico indipendente, moltiplicatori a latenza 0/3, shift estremi, errori, reset e risposta bloccata; `make -C tb/verilator test` esegue la regressione integrata.

In caso di errore, non scrivere il valore errato nel temporaneo richiesto: scrivere zero in OUT, impostare status e terminare. Una microistruzione finale deve avere `dst=DST_OUT`; `LAST_OP` ha effetto dopo il writeback, mai al lancio.

Resettare controllo, status e OUT; i temporanei possono evitare reset se ogni programma li inizializza prima di leggerli. Verificare questa proprietà e mantenere gli standard del repository.

## 8. Conversioni numeriche senza campo `format`

Non includere un generico campo format nella microistruzione. La decodifica di `command_reg + micro_pc` determina gli allineamenti e la conversione del risultato. Usare segnali interni typed per i profili numerici, se rendono il codice più leggibile. Non distribuire shift numerici senza nome tra FSM e mux.

| Passo | Trattamento |
| --- | --- |
| SUB coordinate | Calcolo sicuro sul bus originale, verifica range; conserva dx19/dy18 con F8 |
| SUB attributi | Sign extension a 33 bit, memorizza F16 |
| Prodotti iniziali gradienti | Prodotto completo F24 |
| Differenza prodotti gradienti | Numeratore completo F24 |
| RECIP | Packing sign/exponent/mantissa nei 41 bit bassi, resto zero |
| MUL numeratore × reciproco area | Applica segno ed esponente; uscita F16 |
| MUL dx × reciproco dy | Applica segno ed esponente; uscita S(32,12) |
| MUL gx/gy × differenza XY | Prodotto completo F24 |
| MUL sx × differenza Y | Prodotto completo F20 |
| ADD xa + prodotto bordo | Porta xa da F8 a F20 con shift sinistro 12, poi somma |
| ADD a0 + prodotti riferimento | Porta a0 da F16 a F24 con shift sinistro 8, poi somma |
| Scrittura xinitial | Da F20 a F12: arrotonda e shift destro 8, risultato 24 bit |
| Scrittura aref | Da F24 a F16: arrotonda e shift destro 8, risultato 44 bit |

Per un prodotto P tra un operando con F frazionari e la mantissa reciproca a 30 frazionari, il raw risultato a Fout frazionari è:

`Nout = round(P * 2^(exponent + Fout - F - 30))`, applicando anche il segno del reciproco.

Quindi per gradiente, F=24 e Fout=16: shift netto `exponent-38`; per slope, F=8 e Fout=12: `exponent-26`. Questi esponenti si riferiscono al reciproco del valore reale.

Arrotondamento proposto: nearest, ties to even, coerente anche per negativi. Conservare guard/round/sticky dove necessari e verificare overflow dopo l'arrotondamento. Gli shift verso sinistra con possibile overflow vanno controllati prima di troncare: non basta eseguire uno shift in 88 bit e ispezionare soltanto il risultato già troncato. Per uno shift sinistro di k bit, con 0<k<88, tutti i bit originali da 87-k a 86 devono coincidere con il segno originale; per k>=88 soltanto zero è rappresentabile. Questo controllo evita lo shift inverso del risultato troncato. Il conteggio signed a 9 bit copre tutti gli esponenti signed a 8 bit del reciproco (shift da -101 a 166). Per la conversione finale verificare la rappresentabilità nel formato specifico del comando: S(32,16), S(32,12), S(24,12) o S(44,16).

La precisione del reciproco e gli arrotondamenti degli edge slope non garantiscono da soli il corretto top-left coverage dei triangoli adiacenti. La regola di copertura e gli eventuali correttivi appartengono al progetto dello scanline stage; non dichiarare risolto il problema in questa unità.

## 9. Microprogrammi

Nelle tabelle le sorgenti hanno i nomi simbolici delle porte/temporanei; in RTL usare le corrispondenti enum SRC_*. Le operazioni non implicano un ciclo singolo. Conservare prodotti e differenze completi sino alle conversioni definite nella sezione 8.

### CALC_INV_AREA

Ingresso: area; uscita: reciproco D. Il chiamante conserva l'uscita e la fornisce poi su recip_area. D=0 produce errore.

| PC | Op | A | B | Destinazione | Last |
| --- | --- | --- | --- | --- | --- |
| 0 | RECIP | area | UNUSED | OUT | LAST |

### CALC_SLOPE

V0=estremo superiore, V1=estremo inferiore. Richiede y1>y0; il chiamante scarta i bordi orizzontali. `sx=(x1-x0)/(y1-y0)`.

| PC | Op | A | B | Destinazione | Last |
| --- | --- | --- | --- | --- | --- |
| 0 | SUB | y1 | y0 | T0 | MORE |
| 1 | RECIP | T0 | UNUSED | T1 | MORE |
| 2 | SUB | x1 | x0 | T0 | MORE |
| 3 | MUL | T0 | T1 | OUT | LAST |

T1 al PC3 contiene un reciprocal_t: estrarre la mantissa zero-estesa sul B del moltiplicatore e usare segno/esponente nella conversione. Non moltiplicare il bitvector packed come fosse un intero.

### CALC_EDGE_INIT

Ingressi: x0=xa, y0=ya, sx, yref=jstart+0.5. `xinitial=x0+sx*(yref-y0)`.

| PC | Op | A | B | Destinazione | Last |
| --- | --- | --- | --- | --- | --- |
| 0 | SUB | yref | y0 | T0 | MORE |
| 1 | MUL | sx | T0 | T0 | MORE |
| 2 | ADD | x0 | T0 | OUT | LAST |

### CALC_GRAD_X

Vertici originali, non ordinati per Y. `gx=((a1-a0)*(y2-y0)-(a2-a0)*(y1-y0))*recip_area`.

| PC | Op | A | B | Destinazione | Last |
| --- | --- | --- | --- | --- | --- |
| 0 | SUB | a1 | a0 | T0 | MORE |
| 1 | SUB | y2 | y0 | T1 | MORE |
| 2 | MUL | T0 | T1 | T2 | MORE |
| 3 | SUB | a2 | a0 | T0 | MORE |
| 4 | SUB | y1 | y0 | T1 | MORE |
| 5 | MUL | T0 | T1 | T0 | MORE |
| 6 | SUB | T2 | T0 | T0 | MORE |
| 7 | MUL | T0 | recip_area | OUT | LAST |

### CALC_GRAD_Y

`gy=((x1-x0)*(a2-a0)-(x2-x0)*(a1-a0))*recip_area`.

| PC | Op | A | B | Destinazione | Last |
| --- | --- | --- | --- | --- | --- |
| 0 | SUB | x1 | x0 | T0 | MORE |
| 1 | SUB | a2 | a0 | T1 | MORE |
| 2 | MUL | T1 | T0 | T2 | MORE |
| 3 | SUB | x2 | x0 | T0 | MORE |
| 4 | SUB | a1 | a0 | T1 | MORE |
| 5 | MUL | T1 | T0 | T0 | MORE |
| 6 | SUB | T2 | T0 | T0 | MORE |
| 7 | MUL | T0 | recip_area | OUT | LAST |

L'inversione delle sorgenti nei due primi MUL mantiene il prodotto matematico e rende esplicita la mappatura sulle porte 54/33 bit.

### CALC_ATTR_REF

`aref=a0+gx*(xref-x0)+gy*(yref-y0)`; gx/gy salvati dal chiamante. Il riferimento può essere fuori dal triangolo.

| PC | Op | A | B | Destinazione | Last |
| --- | --- | --- | --- | --- | --- |
| 0 | SUB | xref | x0 | T0 | MORE |
| 1 | MUL | gx | T0 | T2 | MORE |
| 2 | SUB | yref | y0 | T0 | MORE |
| 3 | MUL | gy | T0 | T1 | MORE |
| 4 | ADD | T2 | T1 | T0 | MORE |
| 5 | ADD | a0 | T0 | OUT | LAST |

| Comando | Numero microistruzioni |
| --- | --- |
| INV_AREA | 1 |
| SLOPE | 4 |
| EDGE_INIT | 3 |
| GRAD_X | 8 |
| GRAD_Y | 8 |
| ATTR_REF | 6 |

Definire un array localparam di microinstruction_t per ogni comando. Selezionare il programma con case(command_reg), poi indicizzare con micro_pc. Per PC/comandi invalidi evitare accessi fuori limite e terminare con errore. Non introdurre una FSM separata per ogni comando.

## 10. Interazione con il triangle setup

Il controllo esterno trova min/max, ordina gli indici per Y, calcola bounding box/scissor, righe attive e punti di riferimento. Per ogni bordo non orizzontale emette SLOPE, salva sx, emette EDGE_INIT e salva xinitial. Per ogni triangolo emette INV_AREA una volta. Per ogni attributo abilitato emette GRAD_X, GRAD_Y e ATTR_REF salvando i risultati.

Gli indici TOP/MIDDLE/BOTTOM servono per TM/TB/MB; i gradienti e D devono usare la medesima disposizione originale V0/V1/V2. L'unità non genera gradienti per ogni bordo: genera una coppia per attributo dell'intero triangolo.

I comandi operano su un attributo alla volta, rendendo riutilizzabile la stessa unità per z, RGB, UV o attributi per correzione prospettica quando compatibili col formato scelto.

## 11. Requisiti di implementazione: stile, area e timing

Prima di scrivere l'RTL, leggere gli AGENTS.md applicabili e moduli rtl. Copiare il mio stile effettivo di scrittura RTL: convenzioni dei nomi, clock/reset, typedef, always_comb/always_ff, indentazione e uso dei package. Questa specifica non pretende di aver ispezionato sorgenti non forniti.

Ragionare sia per chiarezza del codice sia per area/timing. Scrivere codice essenziale logica semplice, leggibile, senza wrapper inutili, livelli di astrazione gratuiti o duplicazioni. Commenti significativi e concisi, normalmente una o due righe; evitare il wrapping inutile delle singole espressioni. Dare nomi ai formati e agli shift, senza numeri magici nei percorsi dati.

Preservare precisione e range prima di ottimizzare la larghezza. Evitare copie degli ingressi, copie registrate dei microprogrammi, moltiplicatori duplicati e mux universali sovradimensionati. Ridurre i mux alle sorgenti effettivamente selezionate e tenere separate decodifica, controllo e datapath senza creare FSM ridondanti.

Valutare sul target Nexys A7 il costo dei registri larghi, dell'add/sub, dei mux, degli shift variabili del reciproco e delle unità multiciclo. Il numero di bit dell'interfaccia non equivale a una stima dei DSP. Non promettere 100 MHz o un'area specifica senza sintesi e timing report. Eventuali riduzioni dai formati conservativi devono essere motivate da limiti numerici dimostrati, non dal solo caso tipico.

Produrre `triangle_math_unit.sv`, gli eventuali tipi condivisi necessari e i file esterni `triangle_multiplier.sv` e `triangle_reciprocal.sv` con le dipendenze richieste. Il primo contiene i rami `VIVADO`/comportamentale descritti sopra; il secondo deriva dal codice in `perspective_divide/`. Nella triangle_math_unit definire soltanto le istanze di queste due unità. Se sorgenti o strumenti necessari non sono disponibili, documentare il limite concreto; non introdurre stub che simulino risultati corretti o operatori `/` combinatori al posto del reciproco multiciclo.

## 12. Verifica richiesta all'implementazione

Verificare con un modello numerico di riferimento indipendente le formule e le conversioni, includendo coordinate ai bordi del viewport, differenze estreme del dominio 640×480, rifiuto di coordinate negative/off-screen, D positivo/negativo, D raw minimo non nullo, dy minimo non nullo, gradienti negativi, gradienti appena dentro/fuori S(32,16), attributi costanti, riferimenti esterni al triangolo e rounding di valori negativi. Quantificare la tolleranza coerente con l'errore del reciproco, senza confronti floating-point esatti arbitrari.

Controllare protocollo, backpressure prolungata delle unità e dell'uscita, reset durante esecuzione, divisione per zero e overflow. Asserzioni significative: ingressi operando stabili durante transazione; un solo lancio per uistruzione; micro_pc stabile durante attesa; nessuna lettura di temporanei non inizializzati; scrittura OUT soltanto al termine o per errore; uscita stabile quando out_valid && !out_ready; compatibilità della restrizione alle porte 54/33/38 bit per le unità, conservando il bus area GE a 38 bit; nessuna risposta stale dopo reset.

Verificare entrambi i rami del moltiplicatore sugli stessi casi, inclusi estremi signed, prodotti negativi e backpressure. Quando i modelli IP sono disponibili, confrontare il prodotto del ramo VIVADO con quello del ramo `*`, tenendo conto delle diverse latenze tramite handshake. Eseguire sintesi e timing del ramo VIVADO a 100 MHz con i vincoli reali del progetto.

Le approssimazioni del reciproco devono essere valutate separatamente dalla correttezza del sequenziamento. Se l'implementazione cambia una larghezza o un formato, aggiornare questa specifica e i controlli associati.


## 12. Integrazione con i piani RGB444 compatti

Il contratto della math unit resta invariato: a0/a1/a2 e gx/gy sul bus sono S(32,16), risultati gradienti S(32,16), riferimento S(44,16). Non aggiungere un comando o campo format colore. Il chiamante triangle_setup converte i gradienti RGB a S(24,12), arrotondando nearest ties-to-even e controllando overflow prima della scrittura. Per CALC_ATTR_REF ripresenta i gradienti quantizzati con sign-extension a 32 bit e shift sinistro 4. RGB dei vertici è 0..15 convertito a F16.

Il chiamante converte aref a S(36,12), arrotondando di 4 bit e controllando overflow. Gli accumulatori colore a valle mantengono S(36,12). S(32,12) non copre il limite generale del riferimento fuori triangolo: 15+2048*(640+480)=2,293,775. I controlli locali del chiamante devono generare STATUS_OVERFLOW/SETUP_MATH_ERROR anche se out_status della math unit era OK.

I prodotti intermedi, temporanei, unità aritmetiche e microprogrammi rimangono quelli già dimensionati per Z/texture. Il risparmio riguarda i registri dei tre piani colore e il relativo datapath dello scanline stage; non dichiarare una riduzione del moltiplicatore condiviso soltanto perché RGB444 usa meno bit. Per le conversioni dettagliate e la rimappatura degli slot vedere la sezione 12 di triangle_setup_spec.md.


## 13. ABI GE 512 bit e reciproco W

Il proc_triangle_t è esattamente 512 bit: tre vertici da 158 bit e D signed S(38,16). La math unit riceve X19/Y18 F8 e area38 F16. Le differenze XY già dimensionate 19/18 bit restano valide solo dopo la validazione del viewport clippato; SUB sui valori signed generici richiederebbe un bit aggiuntivo. I temporanei 88 bit e il moltiplicatore 54×33 restano dimensionati per gli attributi S(32,16), non per il solo record GE.

U e V trasmessi sono già u/w e v/w signed S(32,16): collegamento diretto agli operandi attributo nella modalità prospettica. Z è z/w U(17,16), zero-esteso a S(32,16). Non dividere nuovamente UV per W.

Il reciproco W del GE (mantissa18 F17 + esponente signed6, senza segno) non è reciprocal_t della math unit (segno1+exp8+mantissa32 F30). Non fare cast/reinterpretazioni tra questi tipi. Per il piano INV_W convertire il valore reale a S(32,16) nel chiamante, con rounding e controllo di range. Con la convenzione valore=mantissa_raw*2^(exponent-17), raw F16=round(mantissa_raw*2^(exponent-1)); verificare tale convenzione, normalizzazione e codifica dello zero nel RTL/documentazione GE. Esponenti negativi richiedono arrotondamento, quelli positivi controllo prima dello shift. Il range del formato encoded non è automaticamente rappresentabile in S(32,16); il contratto corrente rifiuta overflow e, per la modalità prospettica, un valore positivo che diventerebbe zero. Questo è un limite esplicito, da eliminare cambiando scala/formati se i dati GE lo richiedono. Non usare l'unità RECIP per invertire di nuovo il reciproco già fornito.

## Implementation clarification: fixed viewport modes

The implementation receives `viewport_size_i` of type `re_viewport_size_t`.
Zero selects 640x480 and one selects 320x240. This mode must remain stable
from command acceptance through response acceptance. Geometry coordinates
may equal the upper viewport boundary; reference coordinates must be strictly
inside it. Invalid relevant coordinates return `STATUS_OVERFLOW` with zero
payload; no clamping occurs.
Only coordinates used by the command are checked. `CALC_INV_AREA` depends only
on `area_i` and ignores viewport dimensions. The RTL command port is named
`command_i`, following the repository's input-port convention.

Per un triangolo con tre bordi validi e tutti i sette attributi abilitati, con moltiplicatore Vivado a tre stadi e senza stall, il salto delle conversioni identità evita 298 cicli: il setup passa da 1118 a 820 cicli dall’handshake di ingresso a setup_valid_o. Le 27 conversioni finali conservano shift e rounding originali.

La prova del moltiplicatore a due stadi usa la stessa latenza configurata nel wrapper. Nel caso completo sopra la simulazione misura 758 cicli, cioè 62 cicli in meno rispetto ai tre stadi, senza modifiche numeriche. La scansione Vivado di 1/2/3 stadi ha dato WNS rispettivamente -6,245/-2,542/-0,996 ns, in sintesi a 100 MHz. Tre stadi tornano quindi la configurazione predefinita; il setup completo torna a 820 cicli. Restano da risolvere i percorsi dei bordi e da verificare il timing dopo implementazione.
