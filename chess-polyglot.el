;;; chess-polyglot.el --- Polyglot book access for Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2014  Mario Lang

;; Author: Mario Lang <mlang@delysid.org>
;; Keywords: games

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; The polyglot book format uses a 64 bit zorbist hash to encode positions.
;; Since 2 bits are used for tagging in Emacs Lisp, 64 bit values can not be
;; represented as fixnums.  So we split the 64 bit value up into equally sized
;; chunks (32 bit fixnums for now).  781 predefined zorbist hash keys are
;; stored as constants (see `chess-polyglot-zorbist-keys') and used to calculate
;; zorbist hashes from positions.

;; Binary search is employed to quickly find all the moves from a certain
;; position.  These moves are converted to proper chess ply objects (see
;; chess-ply.el).

;; The most interesting functions provided by this file are
;; `chess-polyglot-book-open', `chess-polyglot-book-plies',
;; `chess-polyglot-book-ply' and `chess-polyglot-book-close'.

;; For a detailed description of the polyglot book format, see
;; <URL:http://hardy.uhasselt.be/Toga/book_format.html> or
;; <URL:http://hgm.nubati.net/book_format.html>.

;;; Code:

(eval-when-compile (require 'cl-lib))
(require 'chess-ply)
(require 'chess-pos)

(defsubst chess-polyglot-read-octets (n)
  "Read N octets from the current buffer."
  (let ((val 0))
    (dotimes (_ n (progn (cl-assert (<= val most-positive-fixnum)) val))
      (setq val (logior (lsh val 8)
			(progn (forward-char 1) (preceding-char)))))))

(defsubst chess-polyglot-read-key ()
  "Read a polyglot position hash (a 64 bit value) from the current buffer.
A `cons' with the most significant 32 bits in `car' and the least significant
32 bits in `cdr' is returned."
  (cons (chess-polyglot-read-octets 4) (chess-polyglot-read-octets 4)))

(defun chess-polyglot-read-move ()
  "Read a polyglot move (a 32 bit value) from the current buffer.
The result is a list of the form (FROM-INDEX TO-INDEX PROMOTION WEIGHT)."
  (let ((mask (chess-polyglot-read-octets 2)))
    (pcase (let (r)
	     (dotimes (_ 5 r)
	       (push (logand mask 7) r)
	       (setq mask (ash mask -3))))
      (`(,promotion ,from-rank ,from-file ,to-rank ,to-file)
       (list (chess-rf-to-index (- 7 from-rank) from-file)
	     (chess-rf-to-index (- 7 to-rank) to-file)
	     (nth promotion '(nil ?N ?B ?R ?Q))
	     (chess-polyglot-read-octets 2))))))

(defun chess-polyglot-move-to-ply (position from to promotion weight)
  "Convert a polyglot move for POSITION to a ply.
FROM and TO are integers indicating the square index.
PROMOTION, if non-nil, indicates the piece to promote to.
WEIGHT (an integer) is the relative weight of the move."
  (cl-assert (vectorp position))
  (cl-assert (and (integerp from) (>= from 0) (< from 64)))
  (cl-assert (and (integerp to) (>= to 0) (< to 64)))
  (cl-assert (memq promotion '(nil ?N ?B ?R ?Q)))
  (cl-assert (integerp weight))
  (let* ((color (chess-pos-side-to-move position))
	 (ply (apply #'chess-ply-create position nil
		     (if (and (= from (chess-rf-to-index (if color 7 0) 4))
			      (= from (chess-pos-king-index position color))
			      (= (chess-index-rank from) (chess-index-rank to))
			      (memq (chess-index-file to) '(0 7)))
			 (chess-ply-castling-changes
			  position (= (chess-index-file to) 0))
		       (nconc (list from to)
			      (when promotion (list :promote promotion)))))))
    (chess-ply-set-keyword ply :polyglot-book-weight weight)
    ply))

(defsubst chess-polyglot-skip-learn ()
  "Skip the 32 bit learn value."
  (forward-char 4))

(defconst chess-polyglot-record-size 16
  "The size (in bytes) of a polyglot book entry.")

(defsubst chess-polyglot-goto-record (record)
  "Set point to the beginning of RECORD, a number starting from 0."
  (goto-char (1+ (* record chess-polyglot-record-size))))

(defsubst chess-polyglot-forward-record (n)
  "Move point N book records forward (backward if N is negative).
On reaching end or beginning of buffer, stop and signal error."
  (forward-char (* n chess-polyglot-record-size)))

(defsubst chess-polyglot-key-<= (lhs rhs)
  "Non-nil if the polyglot key LHS is less than or equal to RHS."
  (or (< (car lhs) (car rhs))
      (and (= (car lhs) (car rhs)) (<= (cdr lhs) (cdr rhs)))))

(defun chess-polyglot-read-moves (key)
  "Read all moves associated with KEY from the current buffer."
  (cl-assert (= (% (buffer-size) chess-polyglot-record-size) 0))
  (let ((left 0) (right (1- (/ (buffer-size) chess-polyglot-record-size))))
    (while (< left right)
      (let ((middle (/ (+ left right) 2)))
	(if (chess-polyglot-key-<= key (progn (chess-polyglot-goto-record middle)
					      (chess-polyglot-read-key)))
	    (setq right middle)
	  (setq left (1+ middle)))))
    (cl-assert (= left right))
    (chess-polyglot-goto-record left)
    (let ((moves ()))
      (while (equal key (chess-polyglot-read-key))
	(setq moves (nconc moves (list (chess-polyglot-read-move))))
	(chess-polyglot-skip-learn))
      moves)))

(defconst chess-polyglot-zorbist-keys
  [(2637767806 . 863464769) (720845184 . 95069639) (1155203408 . 610415943)
   (2618685246 . 1655139042) (1971536997 . 1218186377) (848342074 . 540017087)
   (263957791 . 1627660921) (3896152207 . 4076560586) (226391645 . 1484086288)
   (436746274 . 3467632685) (2516964848 . 3797861296) (3491888988 . 3510251221)
   (1086189917 . 1248276018) (18044180 . 1876255637) (1572111136 . 1190386149)
   (597658413 . 2146900428) (97624494 . 2243205793) (1738507407 . 1854916977)
   (1950989311 . 2149575947) (2098318769 . 3283594736) (2194108574 . 2015279052)
   (4079062812 . 2500884588) (856979699 . 2941369318) (1270058469 . 3877737539)
   (2858720366 . 3170717948) (2378012835 . 1387254795) (2278688587 . 2178388503)
   (435406673 . 3555273441) (3031118064 . 1655806655) (2063925420 . 1107589828)
   (3376753832 . 436852829) (615148625 . 1302492416) (1285502018 . 1963045959)
   (346460119 . 1016137793) (2803604355 . 1176288659) (55085973 . 2968618255)
   (1669016372 . 4287873088) (164740250 . 1037634196) (896886403 . 883023163)
   (1935551383 . 2764331555) (410153072 . 4055711755) (533441746 . 1505690343)
   (3541084098 . 3466290517) (3214426080 . 4267541060) (2675233103 . 1951705124)
   (1374411850 . 3115986997) (1552073989 . 3684348154) (4244110986 . 875606593)
   (844343081 . 3115990494) (2356462440 . 135999605) (3116133511 . 377238503)
   (2129956651 . 2197966368) (299173332 . 3276914047) (1701379241 . 745972291)
   (1306570996 . 254977976) (2530644806 . 214138461) (1122123979 . 1667800879)
   (1831591130 . 3801192033) (1116211970 . 920967505) (1594837592 . 2551651254)
   (972591349 . 2046373768) (2479207924 . 1935030411) (1675376029 . 2367888248)
   (3960916618 . 3935874422) (1398143232 . 3265801671) (133930885 . 1520005442)
   (1351827834 . 2829577566) (2076951437 . 2723839804) (435980918 . 2364847828)
   (1668970368 . 3738157273) (2185864314 . 3993911799) (2041407829 . 31969768)
   (346864372 . 2004703094) (4047877822 . 3437142421) (3669961416 . 538399484)
   (616810829 . 4190688246) (3144558884 . 4030272234) (216165387 . 2513010905)
   (2761740594 . 3216997572) (3919406634 . 4096014649) (669429112 . 2434161727)
   (2234904640 . 3111407601) (1421079802 . 1598085235) (1924213810 . 310373675)
   (4002762044 . 2067865415) (2592451728 . 2586110625) (1890340057 . 4031717877)
   (4189625662 . 2577429954) (2276713138 . 3049850801) (2741429688 . 3310307512)
   (2924122950 . 3426712818) (421576781 . 1193704381) (2277442246 . 3030264553)
   (153237420 . 595540057) (4278711886 . 4176286928) (2380848297 . 4030514510)
   (2618700582 . 1303682185) (3018992701 . 185284845) (957243316 . 1291916363)
   (1543415220 . 1898408169) (504378001 . 531073412) (2591337657 . 1692896435)
   (1333852064 . 903543556) (1661259930 . 188168388) (561112646 . 2197961224)
   (1536910315 . 2632972300) (1349168372 . 2307429186) (411152329 . 2745631190)
   (1694697476 . 1081411140) (3755185459 . 2631660711) (4019355068 . 4027326706)
   (2066937809 . 3761668332) (3120395808 . 3878773315) (94890149 . 2109283191)
   (3045629038 . 358812277) (1249184265 . 3465901047) (3477490924 . 2308583306)
   (4114113436 . 3875911716) (1014604031 . 1434513279) (3991324799 . 2222416029)
   (2040431088 . 1539915569) (2253613964 . 4081224332) (2547464012 . 1611168627)
   (2722521980 . 4281500978) (71289574 . 213969824) (2450408597 . 903689630)
   (1894451515 . 364024012) (1939968537 . 374938813) (1447259295 . 3785468557)
   (4021046128 . 1664847745) (3139524504 . 3562928047) (1173487682 . 4065269608)
   (2467266804 . 3907744866) (4284945151 . 3486998177) (2925674454 . 1953016432)
   (3710671816 . 1271453948) (2129465869 . 1422863833) (587093076 . 18243356)
   (3373793513 . 2411305257) (2156648078 . 1791034213) (3737413652 . 1534461430)
   (468575139 . 2935304962) (1129551363 . 3603256834) (2861996892 . 1763494778)
   (2826449619 . 2465197654) (1704209531 . 1014895022) (3738359347 . 3402630390)
   (569410928 . 4095796581) (3021312909 . 2108247612) (2444777957 . 2664129360)
   (282063667 . 3773661258) (682545472 . 3188439005) (3318488457 . 1917822038)
   (1447622272 . 4045023041) (757420137 . 4038580915) (2613420942 . 4146703316)
   (4012836163 . 150381244) (2938127093 . 3428591704) (1208226490 . 3086335530)
   (2935205706 . 1446903363) (430957978 . 3830532479) (1381578755 . 3757172800)
   (4109399782 . 1596778224) (288855589 . 1954372339) (3169178148 . 2256716053)
   (2644780093 . 3895892303) (107966643 . 1071681559) (1304747544 . 2607225372)
   (1359190711 . 1898207171) (3229237120 . 3273634996) (3027167685 . 3863637628)
   (3011615298 . 2883984519) (564135827 . 978463264) (770797430 . 362326607)
   (1983662611 . 1907583229) (4153656423 . 48268960) (3609759233 . 720080177)
   (3727911466 . 1270989899) (200708787 . 2366086947) (744508026 . 393422515)
   (1213261630 . 65757284) (3485747185 . 3845951003) (2958861301 . 1680248217)
   (2598470344 . 3163845864) (2767997908 . 4233451722) (3881113485 . 1492930166)
   (1773764017 . 2764062206) (4189435844 . 2898689174) (4234838742 . 1267095035)
   (2624081078 . 3302114327) (2395569449 . 390426320) (1728307101 . 690284926)
   (3309827454 . 1118258254) (2028172868 . 3888829086) (4271523049 . 909051386)
   (146617804 . 942892565) (2467685867 . 974297806) (2483428231 . 503635829)
   (3743260573 . 2018222096) (1002067894 . 2289153437) (3535252974 . 3738302271)
   (4154611160 . 1002664952) (3623154244 . 2349656961) (3646679180 . 3524329383)
   (862933752 . 4282853607) (2806008282 . 3272780913) (2734037942 . 3828874677)
   (1328176304 . 2137666995) (2278785213 . 2780788825) (381286368 . 1816476193)
   (2074232908 . 2316293454) (4087773386 . 3651330956) (967884669 . 3728964514)
   (4239349185 . 3213509668) (419231360 . 1463788948) (1275421624 . 2672384707)
   (1088456595 . 436245261) (2365565249 . 783696577) (1758083333 . 845223583)
   (2048846183 . 3530914274) (2635948261 . 124738415) (940630937 . 3069598626)
   (839474029 . 1253439921) (902477345 . 165479306) (2836079689 . 2681188273)
   (2007115168 . 2093139645) (1363041891 . 1282466609) (1130479818 . 1063857938)
   (3644959908 . 1260430427) (1385135238 . 46497915) (1386975934 . 3110156681)
   (2635987502 . 4233461619) (1915744629 . 4117939016) (487743653 . 285736599)
   (2049219159 . 3960249250) (69242857 . 3908563670) (1511066720 . 1488527520)
   (215590039 . 1703564952) (1459430344 . 4184955468) (676103291 . 2642967214)
   (83799035 . 3182827979) (1949179493 . 476101251) (2593534694 . 1493478716)
   (2283504289 . 995211746) (1349412676 . 3449243940) (2954378677 . 1878813305)
   (249149717 . 3329151870) (1578231917 . 1483986052) (4135085182 . 890874990)
   (461755528 . 3505523909) (3669622373 . 634949665) (219487622 . 2914465301)
   (2825233742 . 3703631897) (2479105382 . 2935590907) (2582097898 . 3187672881)
   (1221328648 . 1843341402) (2140891889 . 3958868911) (1482849818 . 345750049)
   (751922730 . 3178831411) (3546542069 . 4036458902) (216179596 . 877293293)
   (444615341 . 3117393729) (2424254530 . 494454238) (1344234989 . 3003337991)
   (929188581 . 2760877801) (2507911009 . 1879899982) (980166547 . 1311840394)
   (3566535507 . 1790747461) (143525013 . 2311336672) (4181962471 . 4273938872)
   (1815842366 . 862009811) (911175674 . 1179575598) (3591335374 . 3694215714)
   (1452686093 . 3393294272) (385158879 . 2447709103) (4011414929 . 1264623507)
   (1448477120 . 911094312) (3971299641 . 2289992053) (3133647265 . 2234591563)
   (3007628400 . 964409938) (1708345684 . 3673411261) (3031964479 . 2843021794)
   (3022128657 . 2480338599) (118850112 . 473449293) (2048127371 . 3202109429)
   (3158349745 . 382018770) (1505327237 . 3807570472) (2568424029 . 3272693060)
   (1866609495 . 3888556537) (844703982 . 1852802964) (3504617058 . 682636099)
   (1448882679 . 3733580327) (821387540 . 2215744532) (3631471417 . 311618895)
   (2077838877 . 2383929020) (3352949096 . 1688694420) (2491080787 . 3998672444)
   (3368630402 . 4182204255) (983299419 . 2837414346) (3651215291 . 1033373924)
   (265429091 . 3988955082) (3019003608 . 2896212153) (2955948456 . 3025235588)
   (903690197 . 2266253487) (3925215275 . 89402958) (3959093811 . 3609545561)
   (2455088053 . 223552128) (3115011301 . 2133669107) (1765081558 . 673805649)
   (3324795129 . 2111392191) (3443871631 . 432345706) (3152559950 . 3425427147)
   (3699649406 . 672784944) (3129545774 . 7668664) (2747044893 . 173040075)
   (3925243406 . 852328481) (164095314 . 3161868591) (2234471571 . 1302682825)
   (2164784335 . 105893718) (159995093 . 536831360) (599199451 . 425051327)
   (3274759746 . 1680930461) (1192619331 . 3903085578) (2832721114 . 3078660237)
   (91404660 . 4030521531) (3044880024 . 1578375623) (3906596030 . 754177855)
   (803516785 . 1894094672) (288455592 . 2030430096) (2143232492 . 2317305324)
   (388352703 . 3406060288) (2521731420 . 3588403719) (1043041227 . 4028028525)
   (3195290851 . 2468913324) (4166724431 . 3168683191) (1228226538 . 968516529)
   (500177583 . 3444787306) (533367442 . 4252082053) (4236023256 . 657816314)
   (413575568 . 3367198397) (3435884549 . 3334062733) (1004255532 . 1135705894)
   (2859513268 . 4170618274) (3914086821 . 1251487871) (3080761716 . 3489067886)
   (3571165255 . 699353261) (773372954 . 3648014952) (769693293 . 2939128604)
   (3116440923 . 507748478) (1687629160 . 3739431776) (2489486648 . 3502376324)
   (3686847158 . 2878383449) (3530767427 . 902211375) (2121652637 . 2493976397)
   (1827477891 . 930064171) (2549918411 . 4029725732) (2071415163 . 844118802)
   (2236083679 . 3088894868) (2040110303 . 4144562891) (3489536313 . 1133419300)
   (2190878435 . 2301466071) (2465915458 . 2448602097) (1675766804 . 2073834499)
   (3329799896 . 1613253148) (1483966600 . 1348836071) (159505618 . 2527621997)
   (2674227354 . 1695130688) (2683539437 . 1927873839) (3833196123 . 2570082188)
   (3891433165 . 759819981) (1455453349 . 2179602430) (1430583255 . 1957776111)
   (2067726741 . 4235143439) (303380021 . 2998980439) (2136024795 . 3126725799)
   (2054591852 . 1051702291) (1029141665 . 489794361) (2317027384 . 569642164)
   (2068461795 . 624418658) (2499875684 . 1830645251) (1302894490 . 4319401)
   (1002663431 . 2406815191) (1560941298 . 2060652753) (2141002286 . 515773223)
   (3661248027 . 475092913) (3705503008 . 2419919909) (914567990 . 3496539911)
   (3462935583 . 2039034761) (2878378006 . 2379243316) (1133857586 . 1390159333)
   (3023618742 . 2140726761) (282908558 . 944874642) (3686955701 . 1148723903)
   (2604456805 . 4163675010) (3061545110 . 377179268) (3218002352 . 76459088)
   (2836503392 . 916455101) (536836808 . 151306053) (2886925079 . 404221671)
   (2936593041 . 2011015485) (453815187 . 1852163908) (3042568989 . 82176306)
   (3279635891 . 4174836410) (3282689058 . 2360003049) (4088968807 . 1516570623)
   (2680453086 . 1322680794) (1731693966 . 3438253771) (1842894553 . 1294307894)
   (2736377365 . 2964642609) (121205621 . 521330014) (2324595870 . 3005710757)
   (3784465521 . 676493813) (1958759409 . 2030833406) (1306150933 . 1016370058)
   (2636541290 . 482366508) (1950415745 . 1695073534) (322077955 . 3746046623)
   (3602873262 . 3829181504) (1211684447 . 1861645455) (504701736 . 4080111082)
   (2407799203 . 1223857855) (1925743434 . 1498920209) (3617596327 . 845198428)
   (2498480299 . 3484773806) (2680229135 . 2560201696) (3731399221 . 1536412390)
   (2756509305 . 2924710846) (2635957500 . 3459716133) (1372762539 . 769635894)
   (802677945 . 3878474636) (1707760534 . 3075809808) (3714687192 . 2872792173)
   (1615679922 . 1606381794) (1940556374 . 1337437342) (445390489 . 731124040)
   (2864974375 . 64601760) (1984806574 . 2141516710) (513390958 . 1890172555)
   (744398315 . 1475299139) (982749166 . 852662657) (652663695 . 4260736510)
   (1184061125 . 82616221) (3363191899 . 147951756) (1064069880 . 1507328085)
   (2138882964 . 547595589) (2616926846 . 3186935246) (2298715513 . 3606862940)
   (2414381911 . 811477686) (2694745228 . 900437726) (4202576185 . 2201114451)
   (3602305260 . 3323446937) (3756663274 . 2658490339) (3061587876 . 2171079416)
   (3390977925 . 2850497765) (486312941 . 224925241) (3515712841 . 3510684394)
   (1322319486 . 2647200565) (3839619171 . 1148450258) (392296762 . 1154854654)
   (1401523788 . 957405781) (1934485528 . 527352730) (645968162 . 3131215255)
   (696971825 . 3361451947) (2038689491 . 1946699733) (1723966113 . 2785859721)
   (2652365974 . 1118037185) (3988018407 . 3134982149) (1354171594 . 3053634345)
   (1287854075 . 2631782435) (1723106141 . 2662328866) (563845090 . 1878819261)
   (639520332 . 171129501) (534957223 . 1696062352) (3612364282 . 2283204027)
   (3109494688 . 1304463816) (500957989 . 630925278) (3477030536 . 2149497258)
   (4109750364 . 281719363) (951472732 . 564407054) (922095147 . 2767874048)
   (3946156928 . 829677774) (2622281253 . 2086286851) (2936811901 . 850242186)
   (630086272 . 3340782667) (2340986210 . 1296336989) (4107355543 . 3865114709)
   (3560210278 . 3968418243) (3868847493 . 2967450637) (611513888 . 2083325060)
   (3265390517 . 3025776309) (2874106961 . 3424470508) (1668707698 . 2923258228)
   (2778598353 . 24320552) (292356118 . 3415510793) (754567370 . 86994591)
   (185141877 . 1621715171) (2884558258 . 3722473457) (1492107531 . 111281805)
   (3336927864 . 4225337056) (782994598 . 1021838039) (346133860 . 18281270)
   (2080909533 . 1649329040) (3612065399 . 3859901127) (2151962287 . 284556115)
   (3957975594 . 3745718727) (52533817 . 3998775856) (1232633839 . 397383972)
   (2716413964 . 3629253960) (1531307298 . 3836851439) (3030137657 . 2500401718)
   (3561556693 . 653345841) (313061910 . 2945718466) (2065276 . 3342140708)
   (410498334 . 1470588117) (2726640512 . 4051654894) (2570984935 . 758567696)
   (3008987264 . 3462702678) (623860175 . 228525243) (3527183895 . 1829844480)
   (467272850 . 3890501742) (568376656 . 650516927) (990477018 . 4035508558)
   (2366955227 . 817792110) (4183621538 . 989198068) (946958343 . 1639184195)
   (3395758993 . 3924097558) (1690887473 . 3220519765) (605184237 . 1255270525)
   (275515833 . 1926424610) (2142902612 . 283494960) (2021972412 . 1823828440)
   (105373677 . 3448326697) (1666662384 . 1042433908) (1338566998 . 261206307)
   (498685668 . 1344755577) (3101233780 . 3119109371) (2733370951 . 3808165089)
   (3656512268 . 3449289481) (4025308119 . 1607880299) (778896067 . 1612183167)
   (2846510368 . 3674754715) (3058428120 . 2991822529) (1892379383 . 3268787440)
   (2565895844 . 4154602030) (3213117192 . 98999135) (2495816991 . 116985075)
   (1040203361 . 1785041385) (3106252493 . 69316595) (1639829808 . 2087117568)
   (3213709576 . 3799911752) (604681594 . 2340981536) (4236730699 . 2938666503)
   (4009938384 . 1878897714) (2701667332 . 1725918218) (2182473079 . 1258184)
   (3550198211 . 2760750799) (657991062 . 875584532) (1640976276 . 3380476221)
   (460041378 . 2924352091) (1972323596 . 2287414795) (2510248061 . 1350206297)
   (2959337826 . 3762681165) (1625877874 . 3235902929) (2070189957 . 1429368735)
   (4245163299 . 1839731898) (2358312347 . 138364248) (275739390 . 2179122576)
   (2037777210 . 972544338) (2766930226 . 1984733259) (1933485829 . 4209310327)
   (3034118011 . 3286589799) (2653025529 . 62078937) (2641780289 . 2679545709)
   (3540781195 . 2787026415) (1569993599 . 3215949659) (441337890 . 3947723353)
   (1878946792 . 459505587) (3724105660 . 920173002) (1691411102 . 3934795955)
   (148741087 . 3647709027) (142506469 . 2776440083) (3811107376 . 3823285243)
   (472209891 . 252266174) (1913386482 . 1867329194) (2960608550 . 482740699)
   (1145005292 . 1513558421) (1091751784 . 1687823886) (3625186042 . 3086337482)
   (1712140887 . 940065262) (1504455800 . 1945702563) (3896940088 . 2003245591)
   (2478191531 . 4197739000) (3233871270 . 250924495) (3404865229 . 1131917964)
   (1462204167 . 429621621) (1349259705 . 3641608989) (3627860584 . 2048468319)
   (1244251718 . 1513180369) (3979211282 . 371413143) (3043187861 . 4285699810)
   (581894202 . 3060983825) (1390895705 . 1811317301) (2599134010 . 3337406128)
   (2488233440 . 2436161462) (1816641224 . 2208816697) (1792034756 . 815866116)
   (2779893723 . 2695577703) (2084952115 . 2951772258) (1351806869 . 169269771)
   (2469979804 . 86740603) (1163545420 . 4264616949) (1795352113 . 2511146232)
   (1796715044 . 3134635815) (3521170642 . 1538900329) (3725363621 . 1455009392)
   (1342594643 . 1512127734) (2618386938 . 662157428) (2028859350 . 2494504685)
   (1841905045 . 648351336) (4002935891 . 4033319405) (850071259 . 1768358867)
   (979915719 . 3876018087) (830889197 . 1629549437) (1744763229 . 2455795856)
   (522919199 . 368499868) (3063822504 . 2522639205) (2861636095 . 407686388)
   (4097602344 . 1945259027) (4215946617 . 1251639506) (894485042 . 534122652)
   (924809191 . 1807237502) (1811585710 . 1589663609) (3439653887 . 1722232)
   (3810997538 . 105152714) (2677100683 . 4291805514) (77233985 . 102407776)
   (4239834691 . 2851274395) (148802076 . 2006440603) (2409138150 . 126301601)
   (3048474397 . 3217504870) (588133437 . 4221603123) (1139638106 . 263087485)
   (982032635 . 3165674595) (562514827 . 1294842959) (467575086 . 905357513)
   (1405117894 . 3370530088) (3813285157 . 242912619) (3601878331 . 1985076606)
   (1586505598 . 2092146221) (738488098 . 103663229) (2970334297 . 321718822)
   (1068097019 . 1742926233) (235518094 . 420804527) (283685722 . 4092504887)
   (2666392744 . 3799169331) (3569817788 . 1256762975) (2169728352 . 292617248)
   (2444571896 . 2239859206) (3967907832 . 1066404216) (420376911 . 2913277294)
   (3046293305 . 2956347747) (2311278792 . 2477686209) (2885955184 . 4172514290)
   (3030078181 . 2275536480) (4212469731 . 4280736393) (1046900335 . 1773022229)
   (995380926 . 1414273529) (3892683234 . 2429494358) (615726237 . 2127712535)
   (3880203074 . 2071130305) (176180504 . 3070850165) (1474506861 . 2283723599)
   (1256707747 . 1857412043) (764236850 . 359687368) (3521530334 . 511649419)
   (2318567964 . 3992868140) (128167623 . 2518992858) (2220129756 . 1042300052)
   (2567608573 . 1349636707) (441446694 . 384760969) (4143447316 . 829506048)
   (817912603 . 2738025500) (2368091832 . 357934982) (1187643061 . 1561463042)
   (3438021235 . 3030161697) (1318922279 . 895468690) (434876457 . 1130220303)
   (1180291767 . 1132759596) (2520707785 . 1798553137) (1962430872 . 2958700157)
   (1510954061 . 3534879512) (57831539 . 3269538993) (3354831405 . 3852135009)
   (891783098 . 2698494511) (2555636406 . 996018997) (2881342935 . 3982231648)
   (3473267445 . 2894952368) (1238029452 . 3958679326) (2051805420 . 559465638)
   (3655936674 . 1186951582) (330209165 . 167662935) (1929681327 . 2450868735)
   (1313566811 . 2458925988) (4283920930 . 3243182650) (1438004300 . 4185567150)
   (3093439067 . 89876832) (3401620219 . 3721579956) (3673745794 . 2682874719)
   (3053321309 . 825410712) (822915968 . 3681514755) (3900685126 . 561657358)
   (553823814 . 1857753416) (4166295066 . 983949325) (128359165 . 3426887194)
   (3300989119 . 3884968622) (4193552686 . 3647722552) (452189154 . 1569670618)
   (4122259632 . 3537825460) (2519387887 . 2821594244) (74333898 . 2940550377)
   (4032631446 . 2173999692) (2521268686 . 1934310532) (2620314688 . 2177785789)
   (1378755571 . 2455646622) (394133753 . 4231198609) (734399075 . 2800989170)
   (573292462 . 1634883078) (1214417373 . 3426576256) (2110224475 . 2399009920)
   (2331215665 . 3224086912) (531326186 . 698539511) (3839443603 . 583861850)
   (2644531398 . 2017784332) (616620850 . 3070237104) (590349237 . 2798642861)
   (3582377217 . 3317831670) (1582708616 . 1596570667) (2126148205 . 2358511947)
   (173450736 . 3219362418) (3616831144 . 1323437318) (2655785577 . 3131359031)
   (401600069 . 2967397952) (496349349 . 4244179910) (2479612086 . 2579650653)
   (1710903074 . 2049666425) (3589924952 . 690291925) (3266682943 . 1900485231)
   (1496318498 . 3025542656) (3459221058 . 3389461212) (2091479615 . 3140389256)
   (663040899 . 1207089672) (3323704225 . 1105530508) (353318429 . 2879253542)
   (2674540957 . 941987316) (1688550857 . 620657353) (338551967 . 4286217277)
   (204689992 . 2239736295) (178008789 . 3940832005) (3871613304 . 3300636974)
   (1911672356 . 2429684487) (4055679954 . 1974461722) (3878217928 . 1009991796)
   (2533095482 . 310920740) (2174833823 . 3596041637) (1604814460 . 2939543881)
   (1452830254 . 4092397851) (2441027029 . 4169690209) (3524103304 . 3372213855)

   (836181454 . 1689436944) (4049974663 . 3750330768) (2776523577 . 3710710688)
   (519497435 . 2979405513)

   (1892447193 . 197291556) (3793382197 . 3742120663)
   (3838936 . 2994760034) (479846099 . 1018728609) (3476112862 . 182272649)
   (3504620154 . 1427438450) (2009473484 . 2679350403) (1738755500 . 1129731339)

   (4174784170 . 2938602761)]
  "Zorbist hashes for polyglot.")

(defconst chess-polyglot-zorbist-piece-type '(?p ?P ?n ?N ?b ?B ?r ?R ?q ?Q ?k ?K)
  "Map chess pieces to zorbist hash indexes.")

(defun chess-polyglot-pos-to-key (position)
  "Calculate the polyglot zorbist hash for POSITION.
Uses 781 predefined hash values from `chess-polyglot-zorbist-keys'."
  (cl-assert (vectorp position))
  (let ((h32 0) (l32 0))
    (dotimes (rank 8)
      (dotimes (file 8)
	(let ((piece (cl-position (chess-pos-piece position (chess-rf-to-index
							     rank file))
				  chess-polyglot-zorbist-piece-type)))
	  (when piece
	    (let ((piece-key (aref chess-polyglot-zorbist-keys
				   (+ (* 64 piece) (* (- 7 rank) 8) file))))
	      (setq h32 (logxor h32 (car piece-key))
		    l32 (logxor l32 (cdr piece-key))))))))
    (let ((sides '(?K ?Q ?k ?q)))
      (dolist (side sides)
	(when (chess-pos-can-castle position side)
	  (let ((castle-key (aref chess-polyglot-zorbist-keys
				  (+ 768 (cl-position side sides)))))
	    (setq h32 (logxor h32 (car castle-key))
		  l32 (logxor l32 (cdr castle-key)))))))
    ;; TODO: en passant
    (when (chess-pos-side-to-move position)
      (let ((turn-key (aref chess-polyglot-zorbist-keys 780)))
	(setq h32 (logxor h32 (car turn-key))
	      l32 (logxor l32 (cdr turn-key)))))
    (cons h32 l32)))

;;; Public interface:

(defun chess-polyglot-book-open (file)
  "Open a polyglot book FILE.
Returns a buffer object which contains the binary data."
  (when (file-exists-p file)
    (with-current-buffer (get-buffer-create (concat " *chess-polyglot " file "*"))
      (erase-buffer)
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (current-buffer))))

(defun chess-polyglot-book-plies (book position)
  "Return a list of plies found in BOOK for POSITION.
The resulting list is ordered, most interesting plies come first.
The :polyglot-book-weight ply keyword is used to store the actual move weights.
Use `chess-ply-keyword' on elements of the returned list to retrieve them."
  (cl-assert (bufferp book))
  (cl-assert (vectorp position))
  (let (plies)
    (dolist (move
	     (with-current-buffer book
	       (chess-polyglot-read-moves (chess-polyglot-pos-to-key position)))
	     plies)
      (let ((ply (apply #'chess-polyglot-move-to-ply position move)))
	(when ply
	  (setq plies (nconc plies (list ply))))))))

(defun chess-polyglot-book-ply (book position &optional strength)
  "If non-nil a (randomly picked) ply from plies in BOOK for POSITION.
Random distribution is defined by the relative weights of the found plies.
If non-nil, STRENGTH defines the bias towards better moves.
A value below 1.0 will penalize known good moves while a value
above 1.0 will prefer known good moves.  The default is 1.0.
A strength value of 0.0 will completely ignore move weights and evenly
distribute the probability that a move gets picked."
  (unless strength (setq strength 1.0))
  (cl-assert (and (>= strength 0) (< strength 4)))
  (cl-flet ((ply-weight (ply)
	      (round (expt (chess-ply-keyword ply :polyglot-book-weight)
			   strength))))
    (let* ((plies (chess-polyglot-book-plies book position))
	   (random-value (random (cl-reduce #'+ (mapcar #'ply-weight plies))))
	   (max 0) ply)
      (while plies
	(if (< random-value (setq max (+ max (ply-weight (car plies)))))
	    (setq ply (car plies) plies nil)
	  (setq plies (cdr plies))))
      ply)))

(defalias 'chess-polyglot-book-close 'kill-buffer
  "Close a polyglot book.")

(provide 'chess-polyglot)
;;; chess-polyglot.el ends here
