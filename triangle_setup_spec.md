# Specifica e prompt di implementazione: `triangle_setup.sv`

## 1. Scopo e relazione con la math unit

Implementare il top del triangle setup del Raster Engine diretto di ZenithSoC. `triangle_setup.sv` riceve un triangolo già elaborato dal Geometry Engine, con i tre vertici e il determinante con segno, acquisisce lo stato di rendering associato e prepara un descrittore per lo scanline stage.

Istanziare una sola `triangle_math_unit.sv`, come descritta in `triangle_math_unit_spec.md`. Il top gestisce geometria semplice, sequenziamento dei comandi, salvataggio dei risultati e handshake. La math unit gestisce i microprogrammi aritmetici e istanzia il moltiplicatore/reciproco esterni. Non duplicare nel top moltiplicatori o divisori per rifare i calcoli assegnati alla math unit.

Il modulo non genera frammenti, non accede alla DDR, non legge framebuffer o z-buffer, non esegue texture sampling, z-test o blending. Prepara le informazioni necessarie a tali stage e legge la configurazione generale condivisa dalla pipeline.

Versione iniziale: un solo triangolo in elaborazione e un solo descrittore pendente. L'handshake di uscita può consentire al resto della pipeline di elaborare il triangolo precedente mentre questo modulo prepara quello seguente; la coerenza delle scritture dei pixel rimane responsabilità del controllo del Raster Engine.

## 2. ABI del triangolo e decisioni numeriche

Usare il `proc_triangle_t` del repository, senza ridefinirne arbitrariamente layout, padding o nomi dei campi. Leggere il package reale prima di scrivere l'RTL. La porta di ingresso ha larghezza `$bits(proc_triangle_t)`.

Il nuovo contratto GE contiene esattamente 512 bit, senza padding: tre vertici da 158 bit e D da 38 bit. A occupa [157:0], B [315:158], C [473:316], D [511:474]. La serializzazione DDR usa quattro parole da 128 bit, dalla meno significativa alla più significativa: stride 64 byte. Il percorso diretto trasmette gli stessi bit in un solo trasferimento. Verificare con asserzioni $bits(proc_triangle_t)==512 e $bits(vertex_t)==158 usando il tipo GE reale, senza duplicarlo.

Coordinate X S(19,8), Y S(18,8); Z U(17,16) rappresenta z/w. D S(38,16) è il determinante, cioè la doppia area con segno: `(x1-x0)*(y2-y0)-(x2-x0)*(y1-y0)`. Il record contiene già UV prospettici e il reciproco di W encoded.

D deve corrispondere ai vertici originali nel loro ordine e alle coordinate finali quantizzate ricevute. Non usare un'area calcolata prima di clipping, viewport transform o quantizzazione incompatibile. Il GE scarta già i degeneri: D=0 qui è soltanto un controllo difensivo, non richiede di ricalcolare D con altri moltiplicatori.

Convenzione `S(W,F)` = signed complemento a due con W bit totali e F frazionari; `U(W,F)` = unsigned.

| Dato | Formato | Uso |
| --- | --- | --- |
| X / xref | S(19,8) | Coordinate originali e centri pixel |
| Y / yref | S(18,8) | Coordinate originali e centri pixel |
| Z del GE | U(17,16), z/w | Convertire senza perdita in S(32,16) |
| D | S(38,16) | Compatibile con la math unit |
| Attributo alla math unit | S(32,16) | Contratto comune conservativo della versione attuale |
| Indici pixel prima del clipping | X S(11,0), Y S(10,0) | Rounding e +/-1 nel dominio validato |
| Indici pixel dopo clipping | X U(10,0), Y U(9,0) | Estremi inclusivi entro il viewport |
| Modo viewport | re_viewport_size_t, 1 bit | 0: 640x480, 1: 320x240 |
| gx, gy Z/texture | S(32,16) | Gradienti con overflow controllato |
| gx, gy RGB | S(24,12) | Canali interpolati nella scala 0..15 |
| sx | S(32,12) | Incremento X del bordo per riga |
| xinitial | S(24,12) | X al centro della prima riga attiva |
| aref Z/texture | S(44,16) | Margine per riferimento fuori triangolo |
| aref RGB | S(36,12) | Riferimento e accumulatore colore |
| Reciproco D | 41 bit reciprocal_t | Segno 1 + esponente signed 8 + mantissa U(32,30) |
| Indice vertice | logic [1:0] | V0/V1/V2 con costanti locali |
| Indice bordo | logic [1:0] | TM/TB/MB con costanti locali |
| Indice attributo | logic [2:0] | Slot con costanti condivise |

Il viewport ha origine (0,0) e due sole risoluzioni: **640×480** oppure **320×240**, selezionate dal bit viewport_size_i. Le dimensioni sono costanti locali e non richiedono controlli di validità. Il GE deve consegnare vertici già clippati: 0<=x<=width e 0<=y<=height, con estremi geometrici superiori inclusivi. I pixel sono 0..width-1 e 0..height-1. Validare questo contratto prima dei calcoli ristretti; per coordinate negative/off-screen consegnare un token SETUP_INVALID_CONFIG. Non clampare i singoli vertici per sostituire il clipping del GE. Questo requisito rende possibile restringere differenze, prodotti e parametri dei bordi.

Il profilo compatto è condiviso con la math unit: non allargare indiscriminatamente ogni dato a 96 bit. I gradienti Z/texture oltre S(32,16), o RGB oltre S(24,12) dopo conversione, producono STATUS_OVERFLOW e un token SETUP_MATH_ERROR con discard=1. Questo limite può escludere triangoli estremamente sottili non degeneri: non saturare o troncare per nasconderlo. Gli attributi originali rimangono nativi nel registro del triangolo; la conversione a S(32,16) avviene soltanto sui mux operando math.

## 3. Interfaccia del top

Nomi di porte proposti con suffissi `_i`/`_o`; uniformarli allo stile effettivo del repository prima dell'implementazione.

| Porta | Direzione | Tipo / bit | Significato |
| --- | --- | --- | --- |
| clk_i | input | 1 | Clock |
| rst_ni | input | 1 | Reset attivo basso, coerente con math unit e repository |
| triangle_valid_i | input | 1 | Triangolo e stato di rendering validi |
| triangle_ready_o | output | 1 | Accettazione consentita in IDLE |
| triangle_i | input | proc_triangle_t, $bits del tipo | Tre vertici originali e D |
| gouraud_shading_i | input | 1 | Interpolazione RGB abilitata |
| texture_i | input | 1 | Interpolazione texture abilitata |
| perspective_correct_i | input | 1 | UV prospettici invece di affini; valido quando texture_i=1 |
| z_interpolation_i | input | 1 | Calcolo del piano Z; normalmente abilitato |
| viewport_size_i | input | re_viewport_size_t, 1 bit | 0: 640x480, 1: 320x240 |
| scissor_enable_i | input | 1 | Abilita rettangolo di disegno |
| scissor_xmin_i, scissor_xmax_i | input | ciascuno U(10,0) | Estremi X scissor inclusivi |
| scissor_ymin_i, scissor_ymax_i | input | ciascuno U(9,0) | Estremi Y scissor inclusivi |
| setup_valid_o | output | 1 | Descrittore o token di scarto disponibile |
| setup_ready_i | input | 1 | Scanline stage pronto ad accettare |
| bb_x_start_o, bb_x_end_o | output | ciascuno logic [9:0] | Bbox X inclusiva |
| bb_y_start_o, bb_y_end_o | output | ciascuno logic [8:0] | Bbox Y inclusiva |
| edge_tm_o, edge_tb_o, edge_mb_o | output | ciascuno setup_edge_t, 150 bit | Tre bordi su porte nominate |
| attr_o [3:0] | output | array packed di setup_attribute_t, 4×108 bit | Piani Z, TEX_U, TEX_V, INV_W |
| color_o [2:0] | output | array packed di setup_color_plane_t, 3×84 bit | Piani R, G, B |
| attr_valid_o | output | logic [6:0] | Maschera dei piani validi |
| alpha_o [2:0] | output | ciascuno U(4,0), totale 12 | Alpha di A/B/C originali, preservati senza interpolazione |
| flat_r_o, flat_g_o, flat_b_o | output | ciascuno logic [COLOR_CHANNEL_WIDTH-1:0] | Colore flat RGB444; 4 bit unsigned per canale |
| setup_status_o | output | setup_status_t, 3 | Stato della transazione conclusa |
| math_status_o | output | status_t, 2 | Dettaglio dell'eventuale errore aritmetico |
| setup_error_o | output | 1 | Errore aritmetico o configurazione invalida |
| setup_discard_o | output | 1 | Il token non deve generare frammenti |
| busy_o | output | 1 | Non IDLE, inclusa uscita pendente |

Viewport, scissor, gouraud shading, texture, perspective correct e interpolazione Z sono configurazione generale condivisa dalla pipeline: triangle_setup li legge direttamente dalle porte di ingresso, senza registrarli né inoltrarli in uscita. Il controllo esterno mantiene questa configurazione stabile per tutto il draw, fino al drain della pipeline, inclusa la backpressure. Gli stage successivi leggono la stessa configurazione esterna. La maschera degli attributi richiesti è una decodifica combinatoria di questi ingressi.

Il solo triangolo viene acquisito sul fronte `triangle_valid_i && triangle_ready_o`; dopo quel fronte triangle_i può cambiare. Colori flat e alpha sono dati propri del triangolo e rimangono nelle uscite. Il contesto generale è gestito fuori dal setup; non esistono porte draw_context_i/o.

### 3.1 Stato ed errore espliciti in uscita

Le quattro porte di stato sono sideband della stessa transazione del descrittore: sono significative quando `setup_valid_o=1` e vengono consumate sul medesimo handshake `setup_valid_o && setup_ready_i`. Non sono impulsi di un ciclo, eventi sticky o un secondo canale con handshake indipendente. Mantenerle stabili, insieme al descrittore, finché il destinatario non accetta.

Usare soltanto `setup_status_reg` e `math_status_reg` come sorgenti registrate: `setup_status_o` e `math_status_o` sono collegamenti diretti, `setup_error_o` e `setup_discard_o` sono decodifiche combinatorie dei codici. Lo stato non è duplicato in una struct di dati. Non aggiungere un secondo banco di registri di stato. Quando setup_valid_o=0, il consumatore deve ignorare queste porte; possono conservare il valore precedente. Non occorre aggiungere un segnale done: l'handshake di uscita segnala già la conclusione del triangolo.

| setup_status_o | Codifica | setup_error_o | setup_discard_o | math_status_o |
| --- | --- | --- | --- | --- |
| SETUP_OK | 3'b000 | 0 | 0 | STATUS_OK |
| SETUP_EMPTY | 3'b001 | 0 | 1 | STATUS_OK |
| SETUP_DEGENERATE | 3'b010 | 0 | 1 | STATUS_OK |
| SETUP_MATH_ERROR | 3'b011 | 1 | 1 | Codice restituito dalla math unit |
| SETUP_INVALID_CONFIG | 3'b100 | 1 | 1 | STATUS_OK |

I codici 3'b101/110/111 sono riservati. Per una codifica non riconosciuta, la decodifica deve impedire la rasterizzazione (`error=1`, `discard=1`) e una asserzione deve segnalarla.

Riutilizzare `status_t` del package della math unit, senza introdurre un alias math_status_t: STATUS_OK=2'b00, STATUS_DIV_ZERO=2'b01, STATUS_OVERFLOW=2'b10, STATUS_INVALID_CMD=2'b11. Fissare esplicitamente questi valori nei typedef condivisi o verificare la compatibilità con la definizione esistente.

EMPTY e DEGENERATE indicano uno scarto geometrico, senza errore di elaborazione. MATH_ERROR distingue divisione per zero, overflow e comando aritmetico invalido tramite math_status_o. INVALID_CONFIG indica ad esempio coordinate fuori viewport o modalità prospettica priva degli attributi richiesti. busy_o è invece un'indicazione live del modulo, non un campo del risultato.

Inizializzare math_status a STATUS_OK per ogni nuovo triangolo e aggiornarlo solo per un errore math. Per tutti i token con discard=1 invalidare attr_valid ed edge[].valid; il destinatario deve comunque usare discard/status per decidere di non elaborare il token. Il payload geometrico di uno scarto non è significativo.

## 4. Uscite separate per funzione

I gruppi di uscita contengono i dati per generare gli span e interpolare gli attributi per addizioni incrementali. Non esiste una porta setup_o né una struct globale triangle_setup_t. Tutte le porte di risultato condividono un solo handshake setup_valid_o/setup_ready_i; non aggiungere valid/ready per ogni gruppo. Gli estremi di bounding box e intervalli dei bordi sono inclusivi.

### 4.1 Campi geometrici

| Campo | Bit / formato | Significato |
| --- | --- | --- |
| bb_x_start, bb_x_end | ciascuno U(10,0) | Bbox X già intersecata con schermo/scissor |
| bb_y_start, bb_y_end | ciascuno U(9,0) | Bbox Y già intersecata con schermo/scissor |
| edge[TM/TB/MB].valid | 1 | Bordo non orizzontale con almeno una riga attiva |
| edge[].is_left | logic, 1 | 1=sinistro, 0=destro; significativo solo se valid=1 |
| edge[].j_start, edge[].j_end | ciascuno U(9,0) | Righe attive del bordo, inclusive |
| edge[].sx | S(32,12) | Incremento X per una riga di Y |
| edge[].x_initial | S(24,12) | X del bordo al centro di j_start |
| edge[].xa, edge[].xb | ciascuno S(19,8) | Estremi X originali |
| edge[].ya, edge[].yb | ciascuno S(18,8) | Estremi Y originali |

Conservare gli estremi dei bordi nel descrittore rende disponibile la geometria esatta allo scanline stage per regole di copertura/correzioni. Non assumere che un reciproco approssimato con molti bit frazionari garantisca da solo top-left coverage identico per bordi condivisi. La regola esatta per i limiti orizzontali e i correttivi dello scanline stage deve essere definita separatamente.

### 4.2 Piani degli attributi e contesto

| Campo | Bit / formato | Significato |
| --- | --- | --- |
| attr_valid | 7 bit | Maschera dei piani calcolati |
| attr[k].gx, attr[k].gy | ciascuno S(32,16) | Gradienti del piano |
| attr[k].aref | S(44,16) | Valore al riferimento comune, con margine di estrapolazione |
| color[c].gx, color[c].gy | ciascuno S(24,12) | Gradienti R/G/B |
| color[c].aref | S(36,12) | Riferimento e accumulatore R/G/B |
| flat_r, flat_g, flat_b | ciascuno U(COLOR_CHANNEL_WIDTH,0) | Colore flat originale, senza padding frazionario |
| setup_status_o | setup_status_t, 3 | Stato su porta separata |
| math_status_o | status_t, 2 | Dettaglio math su porta separata |

Slot fissi: Z, R, G, B, TEX_U, TEX_V, INV_W. In modalità affine TEX_U/TEX_V rappresentano u/v; in modalità prospettica rappresentano u/w e v/w, INV_W rappresenta 1/w. L'interpretazione viene dal flag perspective_correct, non dal nome del registro.

Piani disabilitati: azzerare i campi logici nel descrittore o mascherarli a zero in uscita; lo scanline stage deve usare attr_valid. Non consegnare dati del triangolo precedente come attributi validi.

Non servono nell'uscita il reciproco dell'area, gli indici dei vertici ordinati o tutti i registri operando della math unit. Xref/Yref sono ricavabili da bb_start+0.5 e non devono essere duplicati nel descrittore.

Nel profilo RGB444 e 640×480 il payload di risultato ammonta a **1208 bit**: bbox 38 + bordi 450 + piani non colore 432 + piani colore 252 + maschera 7 + colore flat 12 + alpha originali 12 + status 3 + math_status 2. La maschera degli attributi è derivata dalla configurazione condivisa, senza un registro dedicato. Error/discard sono decodifiche combinatorie. Sono conteggi dei dati, non stime di LUT/DSP dopo sintesi.

COLOR_CHANNEL_WIDTH è fissato a 4 per RGB444 (oppure parametro default 4 con asserzione che sia 4 per questo profilo). Verificare i campi effettivi del proc_triangle_t senza cambiarne implicitamente ABI o scala. Il valore interpolato è 0..15 per canale, non 0..255.

### 4.3 Package minimale e responsabilità dei tipi

Non mettere ABI GE, tipi dei microprogrammi, FSM del top e dati per lo scanline stage nello stesso package. Usare questa separazione:

| Sede | Contenuto | Regola |
| --- | --- | --- |
| Package GE già esistente | proc_triangle_t e tipi dei vertici | Importare, non duplicare |
| Package della math unit | command_t, reciprocal_t, status_t e tipi delle microistruzioni | Il top usa i tipi di interfaccia; non li ridefinisce |
| triangle_setup_pkg.sv, oppure package di interfaccia Raster già esistente | setup_edge_t, setup_attribute_t, setup_color_plane_t, setup_status_t e costanti slot | Solo tipi condivisi con lo stage successivo |
| Dentro triangle_setup.sv | setup_state_t, math_phase_t, indici e registri interni | Non esportare dettagli della FSM |

Il package setup aggiunge soltanto **quattro typedef**: tre struct semanticamente omogenee e un enum di stato. Non aggiungere alias per ogni larghezza, una struct bbox, una struct per il colore flat, una struct wrapper o un typedef per l'array dei piani. Le costanti dei formati possono essere localparam; non serve un typedef numerico per ognuna.

```systemverilog
package triangle_setup_pkg;
    localparam int unsigned ATTR_COUNT = 7; // Slot logici per il sequenziamento e la maschera
    localparam int unsigned NONCOLOR_COUNT = 4;
    localparam int unsigned COLOR_COUNT = 3;
    localparam int unsigned ATTR_Z = 0;
    localparam int unsigned ATTR_R = 1;
    localparam int unsigned ATTR_G = 2;
    localparam int unsigned ATTR_B = 3;
    localparam int unsigned ATTR_TEX_U = 4;
    localparam int unsigned ATTR_TEX_V = 5;
    localparam int unsigned ATTR_INV_W = 6;

    typedef struct packed {
        logic valid;
        logic is_left;
        logic [8:0] j_start, j_end;
        logic signed [31:0] sx;
        logic signed [23:0] x_initial;
        logic signed [18:0] xa, xb;
        logic signed [17:0] ya, yb;
    } setup_edge_t;

    typedef struct packed {
        logic signed [31:0] gx, gy;
        logic signed [43:0] aref;
    } setup_attribute_t;

    typedef struct packed {
        logic signed [23:0] gx, gy;
        logic signed [35:0] aref;
    } setup_color_plane_t;

    typedef enum logic [2:0] {
        SETUP_OK = 3'b000,
        SETUP_EMPTY = 3'b001,
        SETUP_DEGENERATE = 3'b010,
        SETUP_MATH_ERROR = 3'b011,
        SETUP_INVALID_CONFIG = 3'b100
    } setup_status_t;
endpackage
```

La struct bordo raggruppa dati di un solo bordo; quella attributo raggruppa dati di un solo piano. Nessuna contiene flag globali, stato/errori o contesto texture. is_left è un bit booleano: un enum dedicato non aggiungerebbe informazione utile.

Esempio di porte dati, da integrare con gli ingressi e le porte di protocollo della sezione 3:

```systemverilog
output logic [9:0] bb_x_start_o,
output logic [9:0] bb_x_end_o,
output logic [8:0] bb_y_start_o,
output logic [8:0] bb_y_end_o,
output triangle_setup_pkg::setup_edge_t edge_tm_o,
output triangle_setup_pkg::setup_edge_t edge_tb_o,
output triangle_setup_pkg::setup_edge_t edge_mb_o,
output triangle_setup_pkg::setup_attribute_t attr_o [0:triangle_setup_pkg::NONCOLOR_COUNT-1],
output triangle_setup_pkg::setup_color_plane_t color_o [0:triangle_setup_pkg::COLOR_COUNT-1],
output logic [triangle_setup_pkg::ATTR_COUNT-1:0] attr_valid_o,
output logic [COLOR_CHANNEL_WIDTH-1:0] flat_r_o,
output logic [COLOR_CHANNEL_WIDTH-1:0] flat_g_o,
output logic [COLOR_CHANNEL_WIDTH-1:0] flat_b_o,
output logic [3:0] alpha_o [2:0],
output logic gouraud_shading_o,
output logic texture_o,
output logic perspective_correct_o,
output triangle_setup_pkg::setup_status_t setup_status_o
```

math_status_o usa il tipo status_t del package math reale. Il nome di quel package e quello del package GE vanno verificati nel repository; non creare un package fittizio soltanto per adattarlo a questi esempi. Il contesto generale rimane fuori dagli stage del datapath.

Internamente si possono conservare i bordi in un array di tre setup_edge_t per selezionarli con edge_idx, collegando poi gli elementi alle tre porte nominate. Conservare quattro piani setup_attribute_t e tre piani setup_color_plane_t in array unpacked separati. La maschera attr_valid e attr_idx restano a sette slot logici; rimappare esplicitamente Z/U/V/INV_W agli indici fisici 0/1/2/3 e R/G/B agli indici colore 0/1/2. Non indicizzare attr_o direttamente con attr_idx. Questo non richiede un wrapper packed contenente tutto.

Indici vertice e bordo: logic [1:0] con localparam espliciti VERTEX_0/1/2 ed EDGE_TM/TB/MB dentro il modulo. Indice attributo: logic [2:0], confrontato con le costanti condivise ATTR_*. Evitare cast ad enum per un contatore sequenziale. Non dipendere dall'ordine implicito del packing dei vertici GE.

## 5. Operazioni locali: min/max, ordering e bounding box

### 5.1 Min/max e ordinamento

Da V0/V1/V2 originali calcolare xmin/xmax in S(19,8) e ymin/ymax in S(18,8). In parallelo ordinare soltanto gli indici per Y, ottenendo TOP, MIDDLE, BOTTOM. Per Y uguali usare come tie-break l'indice originale, così il risultato è deterministico. Non spostare tutto il payload dei vertici attraverso una rete di sorting.

È sufficiente una rete di compare-swap a tre elementi; ogni swap aggiorna anche un bit di parità della permutazione. I comparatori Y e X sono signed. Tenere le coordinate originali per gradienti e D.

Questo lavoro può essere parallelo nello stato MIN_MAX_ORDER: non deve usare il grande add/sub da 88 bit della math unit. Se la rete di comparatori e mux non rispetta i 10 ns, dividerla con un registro/stato aggiuntivo motivato dal timing.

### 5.2 Conversione in indici pixel candidati

I campioni dei pixel sono `(i+0.5,j+0.5)`. Per ciascun asse:

`candidate_start = ceil(coord_min - 0.5)`.

`candidate_end = floor(coord_max - 0.5)`.

Per una coordinata X S(19,8) o Y S(18,8), definire I=floor(coord) ottenuto con arithmetic shift destro 8, e F=coord[7:0]. Per negativi I non è il troncamento verso zero.

`ceil(coord - 0.5) = I + (F > 8'h80)`.

`floor(coord - 0.5) = I - (F < 8'h80)`.

Dopo la validazione del dominio, estendere I a signed 11 bit per X o 10 bit per Y prima di +/-1. I min/max geometrici vengono trovati sulle coordinate originali; la bounding box che si conserva è intera e non centrata. Non arrotondare semplicemente per eccesso/per difetto senza il mezzo pixel.

### 5.3 Clipping a schermo/scissor e riferimento

Calcolare limiti effettivi signed 11 bit per X e 10 bit per Y:

`clip_xmin = scissor_enable ? max(0,scissor_xmin) : 0`.

`clip_xmax = scissor_enable ? min(viewport_width-1,scissor_xmax) : viewport_width-1`.

Analogo Y. Zero-estendere i valori unsigned prima di confrontarli con indici signed. I limiti finali sono le costanti 639/319 e 479/239 del modo selezionato. Scissor invertito o intersezione vuota significa SETUP_EMPTY.

`bb_x_start = max(candidate_x_start, clip_xmin)`.

`bb_x_end = min(candidate_x_end, clip_xmax)`.

Analogo Y. Se start>end su un asse, terminare con token SETUP_EMPTY senza chiamare la math unit. Restringere a U(10,0) per X o U(9,0) per Y soltanto dopo aver dimostrato intervallo non negativo e rappresentabile.

Riferimento comune per gli attributi:

`xref = bb_x_start + 0.5`, `yref = bb_y_start + 0.5`.

Nel raw F8, usando 19 bit per X e 18 per Y, costruire `(bb_start << 8) + 128` dopo estensione alla larghezza necessaria. Non mettere a 1 un bit della parte intera: il mezzo pixel è il bit frazionario di peso 2^-1. Il riferimento può trovarsi fuori dal triangolo, è comunque valido per il piano degli attributi.

## 6. Preparazione dei bordi TM, TB, MB

Elaborare in sequenza i tre bordi selezionando gli estremi attraverso gli indici ordinati:

| Bordo | Estremo superiore a | Estremo inferiore b |
| --- | --- | --- |
| TM | TOP | MIDDLE |
| TB | TOP | BOTTOM |
| MB | MIDDLE | BOTTOM |

TB è il bordo lungo. TM è il bordo corto superiore, MB quello inferiore. Non creare due nuovi triangoli e non rifare i gradienti al cambio del bordo corto.

Il centro riga deve rispettare `ya <= j+0.5 < yb`. Pertanto:

`j_start = max(bb_y_start, ceil(ya-0.5))`.

`j_end = min(bb_y_end, ceil(yb-0.5)-1)`.

Gli intermedi delle righe sono signed 10 bit; gli estremi del bordo nell'uscita sono unsigned a 9 bit dopo clipping. Se ya=yb oppure j_start>j_end, impostare valid=0 e passare al bordo successivo senza RECIP(dy). Questo gestisce flat-top, flat-bottom e segmenti senza centri pixel attivi.

Per un bordo valido:

1. Richiedere CALC_SLOPE con V0=(xa,ya), V1=(xb,yb), salvare OUT[31:0] come edge.sx.
2. Costruire ystart=j_start+0.5 in S(18,8).
3. Richiedere CALC_EDGE_INIT con xa, ya, sx e yref=ystart.
4. Salvare OUT[23:0] come edge.x_initial. Conservare j_start/j_end ed estremi geometrici.

Il valore x_initial è riferito a j_start di quel bordo, non sempre a bb_y_start. Questo è essenziale per MB quando inizia dopo le prime righe della bounding box.

### 6.1 Identificazione lato sinistro/destro

Assumere il sistema schermo con Y crescente verso il basso. Determinare il segno dell'area nell'ordine TOP/MIDDLE/BOTTOM usando il segno del D originale e la parità della permutazione: permutazione dispari cambia il segno. Non serve moltiplicare di nuovo né negare numericamente D, basta calcolare il segno risultante.

Con `D_sorted > 0`, MIDDLE è a destra del bordo lungo: TB è LEFT e TM/MB sono RIGHT. Con `D_sorted < 0`, TB è RIGHT e TM/MB sono LEFT. Per un sistema con Y verso l'alto rivalutare esplicitamente la convenzione.

Usare questa regola anche nei casi flat-top/flat-bottom; il bordo orizzontale resta invalido. Se dopo il clipping non esiste alcun bordo valido, restituire SETUP_EMPTY. Una bounding box non vuota non garantisce che il triangolo contenga un campione: lo scanline stage può comunque generare zero frammenti.

## 7. Preparazione degli attributi

### 7.1 Maschera e conversione

| Modalità | Piani abilitati |
| --- | --- |
| z_interpolation=1 | Z |
| gouraud_shading=1 | R,G,B |
| texture=1, perspective_correct=0 | INVALID_CONFIG per questo ABI: non contiene u/v affini |
| texture=1, perspective_correct=1 | TEX_U=u/w, TEX_V=v/w, INV_W=1/w |

Se texture=0, normalizzare perspective_correct a 0 per evitare ambiguità. Senza Gouraud, usare il colore flat del vertice provocatore. Proposta: V0 originale, mai TOP; verificare e rispettare la convenzione del GE/software se già definita.

Z U(17,16) viene zero-esteso a S(32,16). Per RGB444, zero-estendere il canale a 32 bit e applicare shift sinistro 16: valore reale 0..15 in S(32,16). Non normalizzare a 0..255.

U/V sono già u/w e v/w S(32,16): usare direttamente gli operandi attributo per la modalità prospettica. Convertire 1/w encoded secondo la sezione 13. Il record non contiene u/v affini: texture=1 con perspective_correct=0 produce INVALID_CONFIG in questa versione, salvo un adattatore esplicito che ricostruisca u/v con arithmetic e precisione documentate. Non reinterpretare u/w come u e non dividerlo nuovamente per W.

### 7.2 Reciproco D e ciclo degli attributi

Se almeno un attributo è abilitato, richiedere CALC_INV_AREA una volta e conservare il reciprocal_t a 41 bit in recip_area_reg. Se attr_valid=0, saltare questa operazione e completare dopo i bordi.

Per ogni attributo abilitato, selezionare a0/a1/a2 dei vertici ORIGINALI e richiedere in sequenza:

`CALC_GRAD_X`: per Z/texture salva OUT[31:0] nel piano non colore rimappato; per RGB applica la conversione della sezione 12 prima di salvare color[c].gx.

`CALC_GRAD_Y`: come GRAD_X, destinazione gy.

`CALC_ATTR_REF`: presenta gx/gy salvati, a0, V0 originale e xref/yref globali; salva OUT[43:0] per Z/texture. Per RGB riallinea i gradienti memorizzati a F16 e converte il riferimento come nella sezione 12.

Formule:

`gx = ((a1-a0)*(y2-y0) - (a2-a0)*(y1-y0)) / D`.

`gy = ((x1-x0)*(a2-a0) - (x2-x0)*(a1-a0)) / D`.

`aref = a0 + gx*(xref-x0) + gy*(yref-y0)`.

Generare una sola coppia gx/gy per attributo del triangolo, non una coppia per bordo. Non effettuare nuove divisioni per ogni pixel. Le conversioni interne, precisione reciproco e rounding sono definite dalla math unit.

## 8. Architettura di controllo e FSM

Separare la FSM del top dalla FSM microaritmetica. Il top non gestisce i singoli passi MUL/SUB/RECIP e non conosce il numero di cicli del moltiplicatore o del reciproco.

Registri: triangolo acquisito; indici TOP/MIDDLE/BOTTOM e parità; min/max e riferimenti; edge_idx/attr_idx; recip_area_reg; un solo banco di risultati suddiviso in bbox, bordi, piani e stato; math_phase; FSM. I valori gx/gy/sx già salvati nel descrittore possono essere riusati come ingressi, senza copie permanenti ulteriori.

Nel RTL, dopo IDLE, W_CONVERT converte e registra i tre reciproci W in raw F16 unsigned a 48 bit. VALIDATE controlla configurazione, range dei valori registrati e area; soltanto dopo passa a MIN_MAX_ORDER. La conversione e il controllo di range non condividono quindi il percorso verso stato/status. Il conteggio signed a 7 bit copre gli shift da -30 a 33 del formato GE. Questo registro aggiunge un ciclo per triangolo; i valori restano stabili fino alla fine della transazione, compresa la backpressure in OUTPUT.

BBOX registra i limiti arrotondati e limitati da viewport/scissor; BBOX_CHECK verifica se il box è vuoto. I registri conservano 11 bit signed per X e 10 bit signed per Y: un limite finale negativo deve essere verificato prima di restringere alle porte unsigned. EDGE_PREP registra il bordo completo, inclusa validità e righe; EDGE_CHECK decide se richiedere SLOPE oppure avanzare al bordo seguente usando la validità registrata. Questi controlli aggiungono un ciclo per bounding box e uno per bordo, senza duplicare i dati dei bordi.

```systemverilog
typedef enum logic [3:0] {
    IDLE, MIN_MAX_ORDER, BOUNDING_BOX, EDGE_PREP,
    MATH_PREP, MATH_REQUEST, MATH_WAIT, NEXT_EDGE,
    AREA_PREP, ATTR_SELECT, NEXT_ATTRIBUTE, OUTPUT
} setup_state_t;

typedef enum logic [2:0] {
    PHASE_SLOPE, PHASE_EDGE_INIT, PHASE_INV_AREA,
    PHASE_GRAD_X, PHASE_GRAD_Y, PHASE_ATTR_REF
} math_phase_t;
```

Definire setup_state_t e math_phase_t localmente dentro triangle_setup.sv. Non esportarli nel package condiviso; evitare import wildcard di enum interni della math unit che creino collisioni tra nomi come IDLE.

| Stato | Operazioni e transizioni |
| --- | --- |
| IDLE | triangle_ready=1. Sul handshake registra triangolo, inizializza status e passa a MIN_MAX_ORDER |
| MIN_MAX_ORDER | Controlla configurazione e D; calcola/registra min/max e indici ordinati in parallelo. Configurazione invalida o D=0: OUTPUT con status; altrimenti BOUNDING_BOX |
| BOUNDING_BOX | Rounding, intersezione con schermo/scissor e riferimento. Vuota: OUTPUT con EMPTY; altrimenti edge_idx=TM e EDGE_PREP |
| EDGE_PREP | Seleziona estremi, lato e righe attive; salva metadati del bordo. Bordo invalido: NEXT_EDGE; valido: math_phase=SLOPE e MATH_PREP |
| MATH_PREP | Prepara la richiesta e, se abilitato, registra il bundle operandi; poi MATH_REQUEST |
| MATH_REQUEST | math_cmd_valid=1, comando/operandi stabili. Soltanto sul handshake della richiesta passa a MATH_WAIT |
| MATH_WAIT | Attende math_out_valid; accetta e salva il risultato nel campo selezionato. Nessun rilancio o incremento prematuro degli indici |
| NEXT_EDGE | Se resta un bordo, incrementa edge_idx e torna a EDGE_PREP; finiti: controlla validità bordi e vai a AREA_PREP oppure OUTPUT con EMPTY |
| AREA_PREP | Se attr_valid=0 vai a OUTPUT con OK; altrimenti math_phase=INV_AREA e MATH_PREP |
| ATTR_SELECT | Cerca il prossimo attributo abilitato nell'ordine degli slot. Se trovato: math_phase=GRAD_X e MATH_PREP; se nessuno: OUTPUT con OK |
| NEXT_ATTRIBUTE | Avanza attr_idx; se terminato vai a OUTPUT con OK, altrimenti ATTR_SELECT |
| OUTPUT | setup_valid=1, descrittore stabile. Solo sul handshake setup_valid && setup_ready torna a IDLE |

Transizioni da MATH_WAIT dopo risposta OK:

| math_phase | Salvataggio | Passo successivo |
| --- | --- | --- |
| SLOPE | edge[edge_idx].sx | phase=EDGE_INIT, MATH_PREP |
| EDGE_INIT | edge[edge_idx].x_initial | NEXT_EDGE |
| INV_AREA | recip_area_reg | attr_idx=Z, ATTR_SELECT |
| GRAD_X | Piano rimappato: gx, con conversione RGB | phase=GRAD_Y, MATH_PREP |
| GRAD_Y | Piano rimappato: gy, con conversione RGB | phase=ATTR_REF, MATH_PREP |
| ATTR_REF | Piano rimappato: aref, con conversione RGB | NEXT_ATTRIBUTE |

In caso di math_status != OK, memorizzare il dettaglio, impostare SETUP_MATH_ERROR, invalidare piani/bordi e andare a OUTPUT. Non usare dati troncati per rasterizzare. Un token EMPTY/DEGENERATE/ERROR viene comunque consegnato con handshake: lo scanline stage lo consuma senza generare frammenti. Questo rende osservabile la conclusione anche dei triangoli scartati.

Non serve uno stato WAIT distinto per ogni comando: math_phase seleziona il salvataggio e il passo seguente. Non usare un contatore di latenza per presumere che la math unit abbia finito.

## 9. Operandi della math unit e registrazione

Istanziare una sola math unit usando i tipi condivisi di `triangle_math_unit_spec.md`. I mux del top selezionano vertici/attributi da registri stabili; i mux interni della math unit selezionano le sorgenti delle microistruzioni. Sono due livelli con responsabilità diverse.

MATH_PREP registra sempre i 419 bit degli operandi selezionati, nelle larghezze delle porte math, senza struct aggiuntive. Il comando è già conservato in math_command_CRT. Dalla richiesta alla risposta mantenere stabili operandi, comando, edge_idx e attr_idx. Gli aggiornamenti ai risultati avvengono sul fronte della risposta. Non esiste più il parametro REGISTER_MATH_INPUTS. Viewport e configurazione generale restano ingressi condivisi, senza copie nel banco degli operandi.

MATH_PREP precede MATH_REQUEST, così la math unit legge il banco aggiornato. Non caricare gli operandi sullo stesso fronte dell’accettazione della richiesta.

Per porte non usate dal comando scegliere valori deterministici, preferibilmente zero, mantenendoli comunque stabili. Mapping:

| Fase | Operandi significativi |
| --- | --- |
| SLOPE | x0/y0=estremo a, x1/y1=estremo b |
| EDGE_INIT | x0/y0=estremo a, sx salvato, yref=centro j_start del bordo |
| INV_AREA | area=D originale |
| GRAD_X / GRAD_Y | Tutte le coordinate originali, a0/a1/a2 selezionati, recip_area_reg |
| ATTR_REF | a0, x0/y0 originali, xref/yref della bbox, gx/gy del piano |

Un cambio di math_phase dopo una risposta cambia anche la funzione di yref tra riferimento del bordo e riferimento del piano. Non confondere le due origini e non aggiornare questa selezione mentre la math unit è ancora occupata.

## 10. Come lo scanline stage usa il descrittore

Per ogni riga attiva aggiorna i bordi con `x_edge += sx`, iniziando da x_initial alla rispettiva j_start. Usa TB da un lato e il bordo corto valido TM/MB dall'altro. Il salto dal corto superiore a quello inferiore usa il suo x_initial, non un'accumulazione proseguita dal bordo precedente.

Dato il primo pixel coperto x_start della riga j, per ciascun attributo:

`a_row_ref(j) = aref + gy*(j-bb_y_start)`.

`a_start = a_row_ref + gx*(x_start-bb_x_start)`.

aref e gli accumulatori di riferimento usano S(44,16); gx/gy S(32,16) vanno sign-estesi a questa larghezza prima delle somme. Poi incremento per pixel `a += gx`; per la successiva riga al riferimento X fisso `a_row_ref += gy`. Se lo scanline stage salta righe, deve compensare il salto: non usare un solo incremento gy per un salto di più righe.

Queste sono operazioni dello stage seguente, non microprogrammi aggiuntivi di questo top. Avanzare gli accumulatori di frammenti solo quando il protocollo della pipeline lo consente. Il confronto depth, la ricostruzione UV prospettici tramite inv_w e il blending avvengono dopo. Solo sul frammento coperto, convertire al formato nativo destinato a depth/colore/texture con rounding e clamp ove definiti; non ridurre anticipatamente aref fuori triangolo al range dell'attributo finale.

## 11. Area, timing e latenza

Target Nexys A7: 100 MHz, periodo 10 ns, con vincoli reali del progetto. Non affermare timing chiuso senza report dopo implementazione.

Percorsi da controllare: compare-swap Y, selezione degli estremi ordinati, min/max/rounding/clipping, mux attr e vertici verso la math unit, lettura dei piani larghi verso ATTR_REF, decodifica risposta e scrittura nel descrittore. Non concatenare tutta la preparazione geometrica e i mux aritmetici in un unico ciclo.

Preferire comparatori locali stretti per bbox/ordering; una math unit condivisa per i calcoli costosi; un solo banco di risultati per i gruppi di uscita; indici ordinati invece di copie dei vertici; maschera attributi per saltare operazioni non richieste. Non istanziare una math unit per bordo o attributo e non duplicare moltiplicatore/reciproco nel top.

Il descrittore proposto è molto largo: l'area comprende storage dei risultati, mux di selezione e registrazione degli operandi, non solo registri temporanei della math unit. Evitare reset dell'intero datapath se maschere/status e inizializzazione prima dell'uso sono sufficienti e consentiti dallo stile del repository. Non ridurre formati senza prova del range.

Numero di comandi aritmetici per E bordi validi e A attributi abilitati:

`Ncmd = 2*E + (A>0 ? 1+3*A : 0)`.

Numero di microistruzioni eseguite dalla math unit:

`Nuop = 7*E + (A>0 ? 1+22*A : 0)`.

Con E=3 e A=7: 28 comandi, 176 microistruzioni. Non sono 176 cicli: sommare latenza delle operazioni, stati del protocollo interno ed esterno, eventuali stall e backpressure. Non stimare fill rate dal solo numero di microistruzioni.

Possibili ottimizzazioni future, da introdurre solo con misure: restringere i piani, selezionare meno attributi per configurazione statica, ridurre mux, dividere uno stato locale critico, buffering del prossimo triangolo. Non aggiungere ora una seconda math unit o double buffering del descrittore senza un requisito concreto.

## 12. Prompt di implementazione e stile RTL

Prima di implementare, leggere gli AGENTS.md applicabili, il package che definisce proc_triangle_t e moduli rappresentativi del GE/Raster Engine. Copiare il mio stile reale di scrittura RTL: naming, reset, typedef, always_comb/always_ff, indentazione, organizzazione di package e istanze. Non inventare un nuovo stile perché gli esempi di questa specifica usano una convenzione provvisoria.

Scrivere codice chiaro ed essenziale, ragionando contemporaneamente su area e timing. Commenti significativi e concisi, normalmente una o due righe. Evitare wrapper inutili, FSM duplicate, copie di dati non necessarie, numeri magici e wrapping gratuito delle singole espressioni. Dare nomi ai formati e alle conversioni.

Separare controllo, mux operandi e salvataggio risultati, ma senza creare un modulo per ogni singolo calcolo. Usare typedef per le FSM/fasi e i comandi simbolici, riutilizzando quelli math. Per semplici bit, indici e contatori usare logic di larghezza esplicita con costanti nominate: non aggiungere typedef privi di un beneficio concreto. Non usare signedness implicita nelle comparazioni o shift di espressioni troppo strette.

Produrre triangle_setup.sv e i tipi condivisi necessari, istanziando la math unit esistente/coerente con la relativa specifica. Non implementare in questo lavoro lo scanline stage. Segnalare incompatibilità concrete nell'ABI o nei formati prima di far passare una reinterpretazione silenziosa per conversione corretta.

## 13. Verifica richiesta all'implementazione

Usare un modello indipendente per bbox, intervalli attivi, selezione dei lati e piani degli attributi. Provare entrambi i winding, tutte le permutazioni dei vertici, Y uguali, flat-top/flat-bottom, coordinate sul bordo e frazioni attorno a 0.5, rifiuto di coordinate negative/off-screen, scissor parziale/vuoto, entrambi i viewport 320×240 e 640×480, D minimo non nullo, triangoli sottili con gradienti rappresentabili e non rappresentabili, e riferimenti fuori triangolo. Verificare che il secondo caso dia un token di errore e non un piano saturato.

Verificare le combinazioni dei flag e il numero di comandi emessi: piani disabilitati non vengono calcolati; RECIP_AREA è emesso una volta soltanto se serve; i bordi orizzontali non avviano RECIP(dy). Il colore flat proviene dal vertice provocatore originale.

Verificare latenze variabili della math unit, backpressure su richiesta/risposta/uscita, errori aritmetici e reset durante elaborazione. Il triangolo di ingresso può cambiare dopo l’accettazione; la configurazione generale resta stabile fino al drain della pipeline.

Asserzioni significative: un solo triangolo attivo; una sola richiesta math outstanding; operandi math stabili durante la transazione; indici/fase stabili durante attesa; ogni risposta va alla destinazione prevista; descrittore stabile sotto backpressure; nessun risultato vecchio marcato valido; bordi validi con j_start<=j_end e ya<yb; bbox OK entro schermo/scissor; nessuna risposta stale dopo reset.

Verificare anche i sideband: stabilità di setup_status_o/math_status_o/error/discard sotto backpressure; coerenza con i due registri di stato, senza duplicazioni nelle struct dati; errore implica scarto; OK non implica scarto; EMPTY/DEGENERATE non implicano errore; math_status significativo solo per MATH_ERROR e STATUS_OK negli altri casi. Ogni triangolo accettato deve produrre esattamente un handshake di uscita, anche se scartato, salvo reset.

Controllare separatamente la copertura esatta dei campioni nello scanline stage: tolleranze del reciproco e correttezza dei piani non sostituiscono la verifica top-left. Riportare sintesi/risorse/timing per ogni registrazione aggiunta al confine math, senza promettere un miglioramento non misurato.


## 12. Profilo compatto RGB444: conversioni e limiti

Questa sezione specializza per RGB le indicazioni generiche attr[k] e S(32,16)/S(44,16) del documento. Z, UV e INV_W mantengono quei formati; i tre piani RGB usano S(24,12) per gx/gy e S(36,12) per aref e accumulatori. Ogni piano colore occupa 84 bit, senza padding a 108 bit. Usare i quattro typedef sopra, senza wrapper aggiuntivi.

La math unit rimane condivisa e calcola con il contratto S(32,16). Al writeback di GRAD_X/Y RGB, arrotondare nearest ties-to-even da F16 a F12 (shift destro 4), quindi verificare la rappresentabilità signed a 24 bit prima di restringere. Il range è [-2048,2048). Su overflow impostare math_status_reg=STATUS_OVERFLOW e SETUP_MATH_ERROR, invalidare piani/bordi e consegnare lo scarto: questo controllo locale è necessario anche quando la math unit ha restituito OK.

Per ATTR_REF usare proprio i gradienti RGB già arrotondati e salvati: sign-extension a 32 bit, poi shift sinistro 4 per presentarli come S(32,16). Il risultato aref S(44,16) viene arrotondato di 4 bit e verificato prima di salvarlo in S(36,12). Non ricalcolare il riferimento usando i gradienti precedenti alla quantizzazione: riferimento e incrementi devono descrivere lo stesso piano. Mux e registrazione degli operandi mantengono le larghezze del bus math esistente; non serve aggiungere una modalità colore, opcode o campo format alla microistruzione.

Con |gx|,|gy|<=2048 e differenze di coordinate <=640/480, |aref|<=15+2048*(640+480)=2,293,775. S(36,12) copre circa ±8,388,608; conserva margine anche negli aggiornamenti lungo la bbox. La proposta precedente S(32,12), circa ±524,288, non copre questo limite generale: non usarla senza ulteriori restrizioni. Conservare intermedi completi per prodotti e somme dello scanline stage e controllare prima di restringere.

La sola quantizzazione diretta F12 del gradiente ha errore <=0.5*2^-12 per passo: su 640 passi <=0.078125 livelli di colore e su 640+480 passi <=0.136719. Calcolando prima F16 e poi F12, includere anche il primo arrotondamento (limite combinato per gradiente <=0.5*2^-16+0.5*2^-12), l'errore del reciproco e quello del riferimento. Non promettere identità bit-esatta dei colori finali vicino alle soglie di arrotondamento.

Per lo scanline stage mantenere riferimenti e accumulatori RGB S(36,12), sign-estendere gx/gy prima degli incrementi. Soltanto per il frammento coperto arrotondare il colore a intero e clampare a [0,15], ottenendo R4/G4/B4. Non clampare aref o i riferimenti di riga fuori dal triangolo. Verificare sfumature orizzontali, verticali e diagonali, valori vicini alle soglie, triangoli sottili e overflow delle conversioni. RGB444 limita il colore ai vertici, non garantisce gradienti piccoli.


## 13. Layout GE aggiornato e contratto del percorso diretto

### 13.1 Vertice da 158 bit

| Bit relativi al vertice | Campo | Formato |
| --- | --- | --- |
| 3:0 | a | U(4,0) |
| 7:4 | b | U(4,0) |
| 11:8 | g | U(4,0) |
| 15:12 | r | U(4,0) |
| 47:16 | v/w | S(32,16) |
| 79:48 | u/w | S(32,16) |
| 85:80 | reciprocal W exponent | signed 6 |
| 103:86 | reciprocal W mantissa | U(18,17), Q1.17 |
| 120:104 | z/w | U(17,16), Q1.16 |
| 138:121 | y | S(18,8) |
| 157:139 | x | S(19,8) |

Importare il package GE e accedere ai campi reali, verificando questo packing. A/B/C sono V0/V1/V2 originali: sorting Y non modifica l'associazione di D e attributi. Conservare alpha_o[0:2] nell'ordine A/B/C, con lo stesso handshake del descrittore; questa revisione non definisce alpha shading/blending né aggiunge un ottavo piano. Non usare alpha come bit valid o padding.

Per INV_W decoded, assumendo la convenzione GE valore=(mantissa_raw/2^17)*2^exponent, ottenere raw F16=round(mantissa_raw*2^(exponent-1)), poi zero-extension e controllo S(32,16). Verificare convenzione e zero encoding nel GE prima dell'RTL. Usare shift, rounding ties-to-even e controllo prima di restringere; nessun nuovo divisore. In modalità prospettica valori encoded invalidi/zero danno INVALID_CONFIG; overflow o underflow di un valore positivo a zero durante conversione danno SETUP_MATH_ERROR/STATUS_OVERFLOW (codice range error disponibile). Non lasciare un piano INV_W zero valido. La precisione F16 e il range della conversione sono restrizioni esplicite del raster, non garanzie del formato encoded.

### 13.2 Ingresso senza ready: integrazione da risolvere

Le porte triangle_valid_i/triangle_ready_o di triangle_setup rimangono un canale interno con backpressure. NON collegare raster_valid_o direttamente a triangle_valid_i presumendo che il setup accetti tutti i cicli: il GE non riceve ready. Serve un frontend che catturi ogni raster_valid_o in un buffer di record completi da 512 bit (con il contesto rendering coerente), poi svuoti il buffer tramite valid/ready verso il setup. Consecutive valid sono trasferimenti distinti, anche con payload uguale.

Un FIFO finito assorbe solo burst limitati: senza una bound su triangoli per job, durata/rate dei burst e stalli del raster, non garantisce assenza di perdite. Capacità richiesta almeno max_t(A(t)-C(t)), dove A è il numero di triangoli arrivati e C quello già rimosso dal frontend. Se il raster può restare fermo per un intero job di N triangoli, il buffer deve poter conservare N record, cioè 64*N byte più metadati; sostenere un trasferimento ogni ciclo resta un requisito del frontend. DDR come spill richiede dimostrare throughput e buffering degli stalli, non elimina il problema da sola.

Alternative ammissibili: aggiungere ready al GE; imporre una bound e prenotare capacità per l'intero job; oppure usare il percorso DDR pull per job che non rispettano tale bound. Una piccola FIFO da pochi triangoli non completa il contratto valid-only. STOP non è una risposta immediata alla FIFO piena: i triangoli già in flight continuano a drenare, e occorre riservare spazio per tutti loro.

Finché bound/capacità/policy non sono definite, il supporto lossless della modalità diretta è una decisione architetturale aperta. Su un overflow inatteso il frontend deve segnalare un errore di job e rendere visibile la perdita; non continuare silenziosamente né presentare l'interfaccia come lossless. Non aggiungere questo errore globale ai soli token setup, perché il record perso non raggiunge il setup.

### 13.3 Switching, completion e fetch DDR

La selezione raster_forward è live: cambiarla solo senza triangoli interessati in flight; il cambio non svuota le code packer precedenti. Drain dei precedenti output DDR oppure soft reset prima del nuovo job, secondo il software GE. Soft reset GE non resetta implicitamente i buffer raster: coordinare flush/reset dei due motori ed evitare residui di contesto. Clearing enable sopprime valid; non campionare dati senza raster_valid_o.

GE_TRI_OUTPUT conta i trasferimenti accettati dal GE; non dimostra completamento del raster. DONE/interrupt GE restano legati all'ingresso completion esterno esistente: il controllo del raster deve distinguere fine arrivi, fine setup, drain dei frammenti e writeback prima di segnalare fine draw. STOP permette al lavoro in flight di arrivare ancora.

Nel percorso memoria ricostruire il record da esattamente quattro parole accettate, P[127:0], P[255:128], P[383:256], P[511:384]. Una read a FIFO vuota non è una nuova parola, anche se il bus mantiene il valore precedente. Conteggio parole zero non prova che il packer sia vuoto: possono esserci triangoli in coda o serializzazione pendente. Reset abbandona il record parziale; non combinare parole prima e dopo reset.
