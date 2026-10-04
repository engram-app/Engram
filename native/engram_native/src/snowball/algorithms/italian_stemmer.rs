//! Generated from italian.sbl by Snowball 3.1.1 - https://snowballstem.org/

#![allow(non_snake_case)]
#![allow(non_upper_case_globals)]
#![allow(unused_mut)]
#![allow(unused_parens)]
#![allow(unused_variables)]
use crate::snowball::SnowballEnv;
use crate::snowball::Among;

#[derive(Clone)]
struct Context {
}

static A_0: &'static [Among<Context>; 7] = &[
    Among("", -1, 7, None),
    Among("qu", 0, 6, None),
    Among("á", 0, 1, None),
    Among("é", 0, 2, None),
    Among("í", 0, 3, None),
    Among("ó", 0, 4, None),
    Among("ú", 0, 5, None),
];

static A_1: &'static [Among<Context>; 3] = &[
    Among("", -1, 3, None),
    Among("I", 0, 1, None),
    Among("U", 0, 2, None),
];

static A_2: &'static [Among<Context>; 37] = &[
    Among("la", -1, -1, None),
    Among("cela", 0, -1, None),
    Among("gliela", 0, -1, None),
    Among("mela", 0, -1, None),
    Among("tela", 0, -1, None),
    Among("vela", 0, -1, None),
    Among("le", -1, -1, None),
    Among("cele", 6, -1, None),
    Among("gliele", 6, -1, None),
    Among("mele", 6, -1, None),
    Among("tele", 6, -1, None),
    Among("vele", 6, -1, None),
    Among("ne", -1, -1, None),
    Among("cene", 12, -1, None),
    Among("gliene", 12, -1, None),
    Among("mene", 12, -1, None),
    Among("sene", 12, -1, None),
    Among("tene", 12, -1, None),
    Among("vene", 12, -1, None),
    Among("ci", -1, -1, None),
    Among("li", -1, -1, None),
    Among("celi", 20, -1, None),
    Among("glieli", 20, -1, None),
    Among("meli", 20, -1, None),
    Among("teli", 20, -1, None),
    Among("veli", 20, -1, None),
    Among("gli", 20, -1, None),
    Among("mi", -1, -1, None),
    Among("si", -1, -1, None),
    Among("ti", -1, -1, None),
    Among("vi", -1, -1, None),
    Among("lo", -1, -1, None),
    Among("celo", 31, -1, None),
    Among("glielo", 31, -1, None),
    Among("melo", 31, -1, None),
    Among("telo", 31, -1, None),
    Among("velo", 31, -1, None),
];

static A_3: &'static [Among<Context>; 5] = &[
    Among("ando", -1, 1, None),
    Among("endo", -1, 1, None),
    Among("ar", -1, 2, None),
    Among("er", -1, 2, None),
    Among("ir", -1, 2, None),
];

static A_4: &'static [Among<Context>; 4] = &[
    Among("ic", -1, -1, None),
    Among("abil", -1, -1, None),
    Among("os", -1, -1, None),
    Among("iv", -1, 1, None),
];

static A_5: &'static [Among<Context>; 3] = &[
    Among("ic", -1, 1, None),
    Among("abil", -1, 1, None),
    Among("iv", -1, 1, None),
];

static A_6: &'static [Among<Context>; 51] = &[
    Among("ica", -1, 1, None),
    Among("logia", -1, 3, None),
    Among("osa", -1, 1, None),
    Among("ista", -1, 1, None),
    Among("iva", -1, 9, None),
    Among("anza", -1, 1, None),
    Among("enza", -1, 5, None),
    Among("ice", -1, 1, None),
    Among("atrice", 7, 1, None),
    Among("iche", -1, 1, None),
    Among("logie", -1, 3, None),
    Among("abile", -1, 1, None),
    Among("ibile", -1, 1, None),
    Among("usione", -1, 4, None),
    Among("azione", -1, 2, None),
    Among("uzione", -1, 4, None),
    Among("atore", -1, 2, None),
    Among("ose", -1, 1, None),
    Among("ante", -1, 1, None),
    Among("mente", -1, 1, None),
    Among("amente", 19, 7, None),
    Among("iste", -1, 1, None),
    Among("ive", -1, 9, None),
    Among("anze", -1, 1, None),
    Among("enze", -1, 5, None),
    Among("ici", -1, 1, None),
    Among("atrici", 25, 1, None),
    Among("ichi", -1, 1, None),
    Among("abili", -1, 1, None),
    Among("ibili", -1, 1, None),
    Among("ismi", -1, 1, None),
    Among("usioni", -1, 4, None),
    Among("azioni", -1, 2, None),
    Among("uzioni", -1, 4, None),
    Among("atori", -1, 2, None),
    Among("osi", -1, 1, None),
    Among("anti", -1, 1, None),
    Among("amenti", -1, 6, None),
    Among("imenti", -1, 6, None),
    Among("isti", -1, 1, None),
    Among("ivi", -1, 9, None),
    Among("ico", -1, 1, None),
    Among("ismo", -1, 1, None),
    Among("oso", -1, 1, None),
    Among("amento", -1, 6, None),
    Among("imento", -1, 6, None),
    Among("ivo", -1, 9, None),
    Among("ità", -1, 8, None),
    Among("istà", -1, 1, None),
    Among("istè", -1, 1, None),
    Among("istì", -1, 1, None),
];

static A_7: &'static [Among<Context>; 87] = &[
    Among("isca", -1, 1, None),
    Among("enda", -1, 1, None),
    Among("ata", -1, 1, None),
    Among("ita", -1, 1, None),
    Among("uta", -1, 1, None),
    Among("ava", -1, 1, None),
    Among("eva", -1, 1, None),
    Among("iva", -1, 1, None),
    Among("erebbe", -1, 1, None),
    Among("irebbe", -1, 1, None),
    Among("isce", -1, 1, None),
    Among("ende", -1, 1, None),
    Among("are", -1, 1, None),
    Among("ere", -1, 1, None),
    Among("ire", -1, 1, None),
    Among("asse", -1, 1, None),
    Among("ate", -1, 1, None),
    Among("avate", 16, 1, None),
    Among("evate", 16, 1, None),
    Among("ivate", 16, 1, None),
    Among("ete", -1, 1, None),
    Among("erete", 20, 1, None),
    Among("irete", 20, 1, None),
    Among("ite", -1, 1, None),
    Among("ereste", -1, 1, None),
    Among("ireste", -1, 1, None),
    Among("ute", -1, 1, None),
    Among("erai", -1, 1, None),
    Among("irai", -1, 1, None),
    Among("isci", -1, 1, None),
    Among("endi", -1, 1, None),
    Among("erei", -1, 1, None),
    Among("irei", -1, 1, None),
    Among("assi", -1, 1, None),
    Among("ati", -1, 1, None),
    Among("iti", -1, 1, None),
    Among("eresti", -1, 1, None),
    Among("iresti", -1, 1, None),
    Among("uti", -1, 1, None),
    Among("avi", -1, 1, None),
    Among("evi", -1, 1, None),
    Among("ivi", -1, 1, None),
    Among("isco", -1, 1, None),
    Among("ando", -1, 1, None),
    Among("endo", -1, 1, None),
    Among("Yamo", -1, 1, None),
    Among("iamo", -1, 1, None),
    Among("avamo", -1, 1, None),
    Among("evamo", -1, 1, None),
    Among("ivamo", -1, 1, None),
    Among("eremo", -1, 1, None),
    Among("iremo", -1, 1, None),
    Among("assimo", -1, 1, None),
    Among("ammo", -1, 1, None),
    Among("emmo", -1, 1, None),
    Among("eremmo", 54, 1, None),
    Among("iremmo", 54, 1, None),
    Among("immo", -1, 1, None),
    Among("ano", -1, 1, None),
    Among("iscano", 58, 1, None),
    Among("avano", 58, 1, None),
    Among("evano", 58, 1, None),
    Among("ivano", 58, 1, None),
    Among("eranno", -1, 1, None),
    Among("iranno", -1, 1, None),
    Among("ono", -1, 1, None),
    Among("iscono", 65, 1, None),
    Among("arono", 65, 1, None),
    Among("erono", 65, 1, None),
    Among("irono", 65, 1, None),
    Among("erebbero", -1, 1, None),
    Among("irebbero", -1, 1, None),
    Among("assero", -1, 1, None),
    Among("essero", -1, 1, None),
    Among("issero", -1, 1, None),
    Among("ato", -1, 1, None),
    Among("ito", -1, 1, None),
    Among("uto", -1, 1, None),
    Among("avo", -1, 1, None),
    Among("evo", -1, 1, None),
    Among("ivo", -1, 1, None),
    Among("ar", -1, 1, None),
    Among("ir", -1, 1, None),
    Among("erà", -1, 1, None),
    Among("irà", -1, 1, None),
    Among("erò", -1, 1, None),
    Among("irò", -1, 1, None),
];

static G_v: &'static [u8; 20] = &[17, 65, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 128, 8, 2, 1];

static G_AEIO: &'static [u8; 19] = &[17, 65, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 128, 8, 2];

static G_CG: &'static [u8; 1] = &[17];

pub fn stem(env: &mut SnowballEnv) -> bool {
    let mut context = &mut Context {
    };
    let mut among_var;
    let mut i_p2 : i32;
    let mut i_p1 : i32;
    let mut i_pV : i32;
    let v_1 = env.cursor;
    'lab0: loop {
        let v_2 = env.cursor;
        'replab1: loop{
            let v_3 = env.cursor;
            'lab2: for _ in 0..1 {
                env.bra = env.cursor;
                among_var = env.find_among(A_0, context);
                env.ket = env.cursor;
                match among_var {
                    1 => {
                        env.slice_from("à");
                    }
                    2 => {
                        env.slice_from("è");
                    }
                    3 => {
                        env.slice_from("ì");
                    }
                    4 => {
                        env.slice_from("ò");
                    }
                    5 => {
                        env.slice_from("ù");
                    }
                    6 => {
                        env.slice_from("qU");
                    }
                    7 => {
                        if env.cursor >= env.limit {
                            break 'lab2;
                        }
                        env.next_char();
                    }
                    _ => ()
                }
                continue 'replab1;
            }
            env.cursor = v_3;
            break 'replab1;
        }
        env.cursor = v_2;
        'replab3: loop{
            let v_4 = env.cursor;
            'lab4: for _ in 0..1 {
                'golab5: loop {
                    let v_5 = env.cursor;
                    'lab6: loop {
                        if !env.in_grouping(G_v, 97, 249) {
                            break 'lab6;
                        }
                        env.bra = env.cursor;
                        'lab7: loop {
                            let v_6 = env.cursor;
                            'lab8: loop {
                                if !env.eq_s(&"u") {
                                    break 'lab8;
                                }
                                env.ket = env.cursor;
                                if !env.in_grouping(G_v, 97, 249) {
                                    break 'lab8;
                                }
                                env.slice_from("U");
                                break 'lab7;
                            }
                            env.cursor = v_6;
                            if !env.eq_s(&"i") {
                                break 'lab6;
                            }
                            env.ket = env.cursor;
                            if !env.in_grouping(G_v, 97, 249) {
                                break 'lab6;
                            }
                            env.slice_from("I");
                            break 'lab7;
                        }
                        env.cursor = v_5;
                        break 'golab5;
                    }
                    env.cursor = v_5;
                    if env.cursor >= env.limit {
                        break 'lab4;
                    }
                    env.next_char();
                }
                continue 'replab3;
            }
            env.cursor = v_4;
            break 'replab3;
        }
        break 'lab0;
    }
    env.cursor = v_1;
    'lab9: loop {
        i_pV = env.limit;
        i_p1 = env.limit;
        i_p2 = env.limit;
        let v_7 = env.cursor;
        'lab10: loop {
            'lab11: loop {
                let v_8 = env.cursor;
                'lab12: loop {
                    if !env.in_grouping(G_v, 97, 249) {
                        break 'lab12;
                    }
                    'lab13: loop {
                        let v_9 = env.cursor;
                        'lab14: loop {
                            if !env.out_grouping(G_v, 97, 249) {
                                break 'lab14;
                            }
                            if !env.go_out_grouping(G_v, 97, 249) {
                                break 'lab14;
                            }
                            env.next_char();
                            break 'lab13;
                        }
                        env.cursor = v_9;
                        if !env.in_grouping(G_v, 97, 249) {
                            break 'lab12;
                        }
                        if !env.go_in_grouping(G_v, 97, 249) {
                            break 'lab12;
                        }
                        env.next_char();
                        break 'lab13;
                    }
                    break 'lab11;
                }
                env.cursor = v_8;
                'lab15: loop {
                    if !env.eq_s(&"divan") {
                        break 'lab15;
                    }
                    break 'lab11;
                }
                env.cursor = v_8;
                if !env.out_grouping(G_v, 97, 249) {
                    break 'lab10;
                }
                'lab16: loop {
                    let v_10 = env.cursor;
                    'lab17: loop {
                        if !env.out_grouping(G_v, 97, 249) {
                            break 'lab17;
                        }
                        if !env.go_out_grouping(G_v, 97, 249) {
                            break 'lab17;
                        }
                        env.next_char();
                        break 'lab16;
                    }
                    env.cursor = v_10;
                    if !env.in_grouping(G_v, 97, 249) {
                        break 'lab10;
                    }
                    if env.cursor >= env.limit {
                        break 'lab10;
                    }
                    env.next_char();
                    break 'lab16;
                }
                break 'lab11;
            }
            i_pV = env.cursor;
            break 'lab10;
        }
        env.cursor = v_7;
        let v_11 = env.cursor;
        'lab18: loop {
            if !env.go_out_grouping(G_v, 97, 249) {
                break 'lab18;
            }
            env.next_char();
            if !env.go_in_grouping(G_v, 97, 249) {
                break 'lab18;
            }
            env.next_char();
            i_p1 = env.cursor;
            if !env.go_out_grouping(G_v, 97, 249) {
                break 'lab18;
            }
            env.next_char();
            if !env.go_in_grouping(G_v, 97, 249) {
                break 'lab18;
            }
            env.next_char();
            i_p2 = env.cursor;
            break 'lab18;
        }
        env.cursor = v_11;
        break 'lab9;
    }
    env.limit_backward = env.cursor;
    env.cursor = env.limit;
    let v_12 = env.limit - env.cursor;
    'lab19: loop {
        env.ket = env.cursor;
        if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((33314 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
            break 'lab19;
        }

        if env.find_among_b(A_2, context) == 0 {
            break 'lab19;
        }
        env.bra = env.cursor;
        if (env.cursor - 1 <= env.limit_backward || (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 111 as u8 && env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 114 as u8)) {
            break 'lab19;
        }

        among_var = env.find_among_b(A_3, context);
        if among_var == 0 {
            break 'lab19;
        }
        if i_pV > env.cursor {
            break 'lab19;
        }
        match among_var {
            1 => {
                env.slice_del();
            }
            2 => {
                env.slice_from("e");
            }
            _ => ()
        }
        break 'lab19;
    }
    env.cursor = env.limit - v_12;
    let v_13 = env.limit - env.cursor;
    'lab20: loop {
        'lab21: loop {
            let v_14 = env.limit - env.cursor;
            'lab22: loop {
                env.ket = env.cursor;
                among_var = env.find_among_b(A_6, context);
                if among_var == 0 {
                    break 'lab22;
                }
                env.bra = env.cursor;
                match among_var {
                    1 => {
                        if i_p2 > env.cursor {
                            break 'lab22;
                        }
                        env.slice_del();
                    }
                    2 => {
                        if i_p2 > env.cursor {
                            break 'lab22;
                        }
                        env.slice_del();
                        let v_15 = env.limit - env.cursor;
                        'lab23: loop {
                            env.ket = env.cursor;
                            if !env.eq_s_b(&"ic") {
                                env.cursor = env.limit - v_15;
                                break 'lab23;
                            }
                            env.bra = env.cursor;
                            if i_p2 > env.cursor {
                                env.cursor = env.limit - v_15;
                                break 'lab23;
                            }
                            env.slice_del();
                            break 'lab23;
                        }
                    }
                    3 => {
                        if i_p2 > env.cursor {
                            break 'lab22;
                        }
                        env.slice_from("log");
                    }
                    4 => {
                        if i_p2 > env.cursor {
                            break 'lab22;
                        }
                        env.slice_from("u");
                    }
                    5 => {
                        if i_p2 > env.cursor {
                            break 'lab22;
                        }
                        env.slice_from("ente");
                    }
                    6 => {
                        if i_pV > env.cursor {
                            break 'lab22;
                        }
                        env.slice_del();
                    }
                    7 => {
                        if i_p1 > env.cursor {
                            break 'lab22;
                        }
                        env.slice_del();
                        let v_16 = env.limit - env.cursor;
                        'lab24: loop {
                            env.ket = env.cursor;
                            if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((4722696 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
                                env.cursor = env.limit - v_16;
                                break 'lab24;
                            }

                            among_var = env.find_among_b(A_4, context);
                            if among_var == 0 {
                                env.cursor = env.limit - v_16;
                                break 'lab24;
                            }
                            env.bra = env.cursor;
                            if i_p2 > env.cursor {
                                env.cursor = env.limit - v_16;
                                break 'lab24;
                            }
                            env.slice_del();
                            match among_var {
                                1 => {
                                    env.ket = env.cursor;
                                    if !env.eq_s_b(&"at") {
                                        env.cursor = env.limit - v_16;
                                        break 'lab24;
                                    }
                                    env.bra = env.cursor;
                                    if i_p2 > env.cursor {
                                        env.cursor = env.limit - v_16;
                                        break 'lab24;
                                    }
                                    env.slice_del();
                                }
                                _ => ()
                            }
                            break 'lab24;
                        }
                    }
                    8 => {
                        if i_p2 > env.cursor {
                            break 'lab22;
                        }
                        env.slice_del();
                        let v_17 = env.limit - env.cursor;
                        'lab25: loop {
                            env.ket = env.cursor;
                            if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((4198408 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
                                env.cursor = env.limit - v_17;
                                break 'lab25;
                            }

                            if env.find_among_b(A_5, context) == 0 {
                                env.cursor = env.limit - v_17;
                                break 'lab25;
                            }
                            env.bra = env.cursor;
                            if i_p2 > env.cursor {
                                env.cursor = env.limit - v_17;
                                break 'lab25;
                            }
                            env.slice_del();
                            break 'lab25;
                        }
                    }
                    9 => {
                        if i_p2 > env.cursor {
                            break 'lab22;
                        }
                        env.slice_del();
                        let v_18 = env.limit - env.cursor;
                        'lab26: loop {
                            env.ket = env.cursor;
                            if !env.eq_s_b(&"at") {
                                env.cursor = env.limit - v_18;
                                break 'lab26;
                            }
                            env.bra = env.cursor;
                            if i_p2 > env.cursor {
                                env.cursor = env.limit - v_18;
                                break 'lab26;
                            }
                            env.slice_del();
                            env.ket = env.cursor;
                            if !env.eq_s_b(&"ic") {
                                env.cursor = env.limit - v_18;
                                break 'lab26;
                            }
                            env.bra = env.cursor;
                            if i_p2 > env.cursor {
                                env.cursor = env.limit - v_18;
                                break 'lab26;
                            }
                            env.slice_del();
                            break 'lab26;
                        }
                    }
                    _ => ()
                }
                break 'lab21;
            }
            env.cursor = env.limit - v_14;
            if env.cursor < i_pV {
                break 'lab20;
            }
            let v_19 = env.limit_backward;
            env.limit_backward = i_pV;
            env.ket = env.cursor;
            if env.find_among_b(A_7, context) == 0 {
                env.limit_backward = v_19;
                break 'lab20;
            }
            env.bra = env.cursor;
            env.slice_del();
            env.limit_backward = v_19;
            break 'lab21;
        }
        break 'lab20;
    }
    env.cursor = env.limit - v_13;
    let v_20 = env.limit - env.cursor;
    'lab27: loop {
        let v_21 = env.limit - env.cursor;
        'lab28: loop {
            env.ket = env.cursor;
            if !env.in_grouping_b(G_AEIO, 97, 242) {
                env.cursor = env.limit - v_21;
                break 'lab28;
            }
            env.bra = env.cursor;
            if i_pV > env.cursor {
                env.cursor = env.limit - v_21;
                break 'lab28;
            }
            env.slice_del();
            env.ket = env.cursor;
            if !env.eq_s_b(&"i") {
                env.cursor = env.limit - v_21;
                break 'lab28;
            }
            env.bra = env.cursor;
            if i_pV > env.cursor {
                env.cursor = env.limit - v_21;
                break 'lab28;
            }
            env.slice_del();
            break 'lab28;
        }
        let v_22 = env.limit - env.cursor;
        'lab29: loop {
            env.ket = env.cursor;
            if !env.eq_s_b(&"h") {
                env.cursor = env.limit - v_22;
                break 'lab29;
            }
            env.bra = env.cursor;
            if !env.in_grouping_b(G_CG, 99, 103) {
                env.cursor = env.limit - v_22;
                break 'lab29;
            }
            if i_pV > env.cursor {
                env.cursor = env.limit - v_22;
                break 'lab29;
            }
            env.slice_del();
            break 'lab29;
        }
        break 'lab27;
    }
    env.cursor = env.limit - v_20;
    env.cursor = env.limit_backward;
    let v_23 = env.cursor;
    'lab30: loop {
        'replab31: loop{
            let v_24 = env.cursor;
            'lab32: for _ in 0..1 {
                env.bra = env.cursor;
                if (env.cursor >= env.limit || (env.current.as_bytes()[(env.cursor + 0) as usize] as u8 != 73 as u8 && env.current.as_bytes()[(env.cursor + 0) as usize] as u8 != 85 as u8)) {among_var = 3;}
                else {
                    among_var = env.find_among(A_1, context);
                }
                env.ket = env.cursor;
                match among_var {
                    1 => {
                        env.slice_from("i");
                    }
                    2 => {
                        env.slice_from("u");
                    }
                    3 => {
                        if env.cursor >= env.limit {
                            break 'lab32;
                        }
                        env.next_char();
                    }
                    _ => ()
                }
                continue 'replab31;
            }
            env.cursor = v_24;
            break 'replab31;
        }
        break 'lab30;
    }
    env.cursor = v_23;
    return true
}
