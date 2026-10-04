//! Generated from dutch.sbl by Snowball 3.1.1 - https://snowballstem.org/

#![allow(non_snake_case)]
#![allow(non_upper_case_globals)]
#![allow(unused_mut)]
#![allow(unused_parens)]
#![allow(unused_variables)]
use crate::snowball::SnowballEnv;
use crate::snowball::Among;

#[derive(Clone)]
struct Context {
    i_p2: i32,
    i_p1: i32,
    S_ch: String,
}

static A_0: &'static [Among<Context>; 21] = &[
    Among("a", -1, 1, None),
    Among("e", -1, 2, None),
    Among("o", -1, 1, None),
    Among("u", -1, 1, None),
    Among("à", -1, 1, None),
    Among("á", -1, 1, None),
    Among("â", -1, 1, None),
    Among("ä", -1, 1, None),
    Among("è", -1, 2, None),
    Among("é", -1, 2, None),
    Among("ê", -1, 2, None),
    Among("eë", -1, 3, None),
    Among("ië", -1, 4, None),
    Among("ò", -1, 1, None),
    Among("ó", -1, 1, None),
    Among("ô", -1, 1, None),
    Among("ö", -1, 1, None),
    Among("ù", -1, 1, None),
    Among("ú", -1, 1, None),
    Among("û", -1, 1, None),
    Among("ü", -1, 1, None),
];

static A_1: &'static [Among<Context>; 8] = &[
    Among("nde", -1, 8, None),
    Among("en", -1, 7, None),
    Among("s", -1, 2, None),
    Among("'s", 2, 1, None),
    Among("es", 2, 4, None),
    Among("ies", 4, 3, None),
    Among("aus", 2, 6, None),
    Among("és", 2, 5, None),
];

static A_2: &'static [Among<Context>; 11] = &[
    Among("de", -1, 5, None),
    Among("ge", -1, 2, None),
    Among("ische", -1, 4, None),
    Among("je", -1, 1, None),
    Among("lijke", -1, 3, None),
    Among("le", -1, 9, None),
    Among("ene", -1, 10, None),
    Among("re", -1, 8, None),
    Among("se", -1, 7, None),
    Among("te", -1, 6, None),
    Among("ieve", -1, 11, None),
];

static A_3: &'static [Among<Context>; 14] = &[
    Among("heid", -1, 3, None),
    Among("fie", -1, 7, None),
    Among("gie", -1, 8, None),
    Among("atie", -1, 1, None),
    Among("isme", -1, 5, None),
    Among("ing", -1, 5, None),
    Among("arij", -1, 6, None),
    Among("erij", -1, 5, None),
    Among("sel", -1, 3, None),
    Among("rder", -1, 4, None),
    Among("ster", -1, 3, None),
    Among("iteit", -1, 2, None),
    Among("dst", -1, 10, None),
    Among("tst", -1, 9, None),
];

static A_4: &'static [Among<Context>; 16] = &[
    Among("end", -1, 9, None),
    Among("atief", -1, 2, None),
    Among("erig", -1, 9, None),
    Among("achtig", -1, 3, None),
    Among("ioneel", -1, 1, None),
    Among("baar", -1, 3, None),
    Among("laar", -1, 5, None),
    Among("naar", -1, 4, None),
    Among("raar", -1, 6, None),
    Among("eriger", -1, 9, None),
    Among("achtiger", -1, 3, None),
    Among("lijker", -1, 8, None),
    Among("tant", -1, 7, None),
    Among("erigst", -1, 9, None),
    Among("achtigst", -1, 3, None),
    Among("lijkst", -1, 8, None),
];

static A_5: &'static [Among<Context>; 3] = &[
    Among("ig", -1, 1, None),
    Among("iger", -1, 1, None),
    Among("igst", -1, 1, None),
];

static A_6: &'static [Among<Context>; 3] = &[
    Among("ft", -1, 2, None),
    Among("kt", -1, 1, None),
    Among("pt", -1, 3, None),
];

static A_7: &'static [Among<Context>; 22] = &[
    Among("bb", -1, 1, None),
    Among("cc", -1, 2, None),
    Among("dd", -1, 3, None),
    Among("ff", -1, 4, None),
    Among("gg", -1, 5, None),
    Among("hh", -1, 6, None),
    Among("jj", -1, 7, None),
    Among("kk", -1, 8, None),
    Among("ll", -1, 9, None),
    Among("mm", -1, 10, None),
    Among("nn", -1, 11, None),
    Among("pp", -1, 12, None),
    Among("qq", -1, 13, None),
    Among("rr", -1, 14, None),
    Among("ss", -1, 15, None),
    Among("tt", -1, 16, None),
    Among("v", -1, 4, None),
    Among("vv", 16, 17, None),
    Among("ww", -1, 18, None),
    Among("xx", -1, 19, None),
    Among("z", -1, 15, None),
    Among("zz", 20, 20, None),
];

static A_8: &'static [Among<Context>; 2] = &[
    Among("d", -1, 1, None),
    Among("t", -1, 2, None),
];

static A_9: &'static [Among<Context>; 6] = &[
    Among("", -1, -1, None),
    Among("eft", 0, 1, None),
    Among("vaa", 0, 1, None),
    Among("val", 0, 1, None),
    Among("vali", 3, -1, None),
    Among("vare", 0, 1, None),
];

static A_10: &'static [Among<Context>; 2] = &[
    Among("ë", -1, 1, None),
    Among("ï", -1, 2, None),
];

static A_11: &'static [Among<Context>; 2] = &[
    Among("ë", -1, 1, None),
    Among("ï", -1, 2, None),
];

static G_E: &'static [u8; 17] = &[1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 120];

static G_AIOU: &'static [u8; 20] = &[1, 65, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 11, 120, 46, 15];

static G_AEIOU: &'static [u8; 20] = &[17, 65, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 139, 127, 46, 15];

static G_v: &'static [u8; 20] = &[17, 65, 16, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 139, 127, 46, 15];

static G_v_WX: &'static [u8; 20] = &[17, 65, 208, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 139, 127, 46, 15];

fn r_V(env: &mut SnowballEnv, context: &mut Context) -> bool {
    let v_1 = env.limit - env.cursor;
    'lab0: loop {
        'lab1: loop {
            if !env.in_grouping_b(G_v, 97, 252) {
                break 'lab1;
            }
            break 'lab0;
        }
        if !env.eq_s_b(&"ij") {
            return false;
        }
        break 'lab0;
    }
    env.cursor = env.limit - v_1;
    return true
}

fn r_C(env: &mut SnowballEnv, context: &mut Context) -> bool {
    let v_1 = env.limit - env.cursor;
    'lab0: loop {
        if !env.eq_s_b(&"ij") {
            break 'lab0;
        }
        return false;
    }
    if !env.out_grouping_b(G_v, 97, 252) {
        return false;
    }
    env.cursor = env.limit - v_1;
    return true
}

fn r_lengthen_V(env: &mut SnowballEnv, context: &mut Context) -> bool {
    let mut among_var;
    let v_1 = env.limit - env.cursor;
    'lab0: loop {
        if !env.out_grouping_b(G_v_WX, 97, 252) {
            break 'lab0;
        }
        env.ket = env.cursor;
        among_var = env.find_among_b(A_0, context);
        if among_var == 0 {
            break 'lab0;
        }
        env.bra = env.cursor;
        match among_var {
            1 => {
                let v_2 = env.limit - env.cursor;
                'lab1: loop {
                    'lab2: loop {
                        if !env.out_grouping_b(G_AEIOU, 97, 252) {
                            break 'lab2;
                        }
                        break 'lab1;
                    }
                    if env.cursor > env.limit_backward {
                        break 'lab0;
                    }
                    break 'lab1;
                }
                env.cursor = env.limit - v_2;
                context.S_ch = env.slice_to();
                let c = env.cursor;
                let (bra, ket) = (env.cursor, env.cursor);
                env.insert(bra, ket, &context.S_ch);
                env.cursor = c;
            }
            2 => {
                let v_3 = env.limit - env.cursor;
                'lab3: loop {
                    'lab4: loop {
                        if !env.out_grouping_b(G_AEIOU, 97, 252) {
                            break 'lab4;
                        }
                        break 'lab3;
                    }
                    if env.cursor > env.limit_backward {
                        break 'lab0;
                    }
                    break 'lab3;
                }
                let v_4 = env.limit - env.cursor;
                'lab5: loop {
                    'lab6: loop {
                        'lab7: loop {
                            if !env.in_grouping_b(G_AIOU, 97, 252) {
                                break 'lab7;
                            }
                            break 'lab6;
                        }
                        if !env.in_grouping_b(G_E, 101, 235) {
                            break 'lab5;
                        }
                        if env.cursor > env.limit_backward {
                            break 'lab5;
                        }
                        break 'lab6;
                    }
                    break 'lab0;
                }
                env.cursor = env.limit - v_4;
                let v_5 = env.limit - env.cursor;
                'lab8: loop {
                    if env.cursor <= env.limit_backward {
                        break 'lab8;
                    }
                    env.previous_char();
                    if !env.in_grouping_b(G_AIOU, 97, 252) {
                        break 'lab8;
                    }
                    if !env.out_grouping_b(G_AEIOU, 97, 252) {
                        break 'lab8;
                    }
                    break 'lab0;
                }
                env.cursor = env.limit - v_5;
                env.cursor = env.limit - v_3;
                context.S_ch = env.slice_to();
                let c = env.cursor;
                let (bra, ket) = (env.cursor, env.cursor);
                env.insert(bra, ket, &context.S_ch);
                env.cursor = c;
            }
            3 => {
                env.slice_from("eëe");
            }
            4 => {
                env.slice_from("iee");
            }
            _ => ()
        }
        break 'lab0;
    }
    env.cursor = env.limit - v_1;
    return true
}

fn r_Step_1c(env: &mut SnowballEnv, context: &mut Context) -> bool {
    let mut among_var;
    env.ket = env.cursor;
    if (env.cursor <= env.limit_backward || (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 100 as u8 && env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 116 as u8)) {
        return false;
    }

    among_var = env.find_among_b(A_8, context);
    if among_var == 0 {
        return false;
    }
    env.bra = env.cursor;
    if context.i_p1 > env.cursor {
        return false;
    }
    if !r_C(env, context) {
        return false;
    }
    match among_var {
        1 => {
            let v_1 = env.limit - env.cursor;
            'lab0: loop {
                if !env.eq_s_b(&"n") {
                    break 'lab0;
                }
                if context.i_p1 > env.cursor {
                    break 'lab0;
                }
                return false;
            }
            env.cursor = env.limit - v_1;
            'lab1: loop {
                let v_2 = env.limit - env.cursor;
                'lab2: loop {
                    if !env.eq_s_b(&"in") {
                        break 'lab2;
                    }
                    if env.cursor > env.limit_backward {
                        break 'lab2;
                    }
                    env.slice_from("n");
                    break 'lab1;
                }
                env.cursor = env.limit - v_2;
                env.slice_del();
                break 'lab1;
            }
        }
        2 => {
            let v_3 = env.limit - env.cursor;
            'lab3: loop {
                if !env.eq_s_b(&"h") {
                    break 'lab3;
                }
                if context.i_p1 > env.cursor {
                    break 'lab3;
                }
                return false;
            }
            env.cursor = env.limit - v_3;
            let v_4 = env.limit - env.cursor;
            'lab4: loop {
                if !env.eq_s_b(&"en") {
                    break 'lab4;
                }
                if env.cursor > env.limit_backward {
                    break 'lab4;
                }
                return false;
            }
            env.cursor = env.limit - v_4;
            env.slice_del();
        }
        _ => ()
    }
    return true
}

fn r_measure(env: &mut SnowballEnv, context: &mut Context) -> bool {
    context.i_p1 = env.limit;
    context.i_p2 = env.limit;
    let v_1 = env.cursor;
    'lab0: loop {
        'replab1: loop{
            'lab2: for _ in 0..1 {
                if !env.out_grouping(G_v, 97, 252) {
                    break 'lab2;
                }
                continue 'replab1;
            }
            break 'replab1;
        }
        let mut v_2 = 1;
        'replab3: loop{
            let v_3 = env.cursor;
            'lab4: for _ in 0..1 {
                'lab5: loop {
                    'lab6: loop {
                        if !env.eq_s(&"ij") {
                            break 'lab6;
                        }
                        break 'lab5;
                    }
                    if !env.in_grouping(G_v, 97, 252) {
                        break 'lab4;
                    }
                    break 'lab5;
                }
                v_2 -= 1;
                continue 'replab3;
            }
            env.cursor = v_3;
            break 'replab3;
        }
        if v_2 > 0 {
            break 'lab0;
        }
        if !env.out_grouping(G_v, 97, 252) {
            break 'lab0;
        }
        context.i_p1 = env.cursor;
        'replab7: loop{
            'lab8: for _ in 0..1 {
                if !env.out_grouping(G_v, 97, 252) {
                    break 'lab8;
                }
                continue 'replab7;
            }
            break 'replab7;
        }
        let mut v_4 = 1;
        'replab9: loop{
            let v_5 = env.cursor;
            'lab10: for _ in 0..1 {
                'lab11: loop {
                    'lab12: loop {
                        if !env.eq_s(&"ij") {
                            break 'lab12;
                        }
                        break 'lab11;
                    }
                    if !env.in_grouping(G_v, 97, 252) {
                        break 'lab10;
                    }
                    break 'lab11;
                }
                v_4 -= 1;
                continue 'replab9;
            }
            env.cursor = v_5;
            break 'replab9;
        }
        if v_4 > 0 {
            break 'lab0;
        }
        if !env.out_grouping(G_v, 97, 252) {
            break 'lab0;
        }
        context.i_p2 = env.cursor;
        break 'lab0;
    }
    env.cursor = v_1;
    return true
}

pub fn stem(env: &mut SnowballEnv) -> bool {
    let mut context = &mut Context {
        i_p2: 0,
        i_p1: 0,
        S_ch: String::new(),
    };
    let mut among_var;
    let mut b_GE_removed : bool;
    let mut b_stemmed : bool;
    b_stemmed = false;
    r_measure(env, context);
    env.limit_backward = env.cursor;
    env.cursor = env.limit;
    let v_1 = env.limit - env.cursor;
    'lab0: loop {
        env.ket = env.cursor;
        if (env.cursor <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((540704 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
            break 'lab0;
        }

        among_var = env.find_among_b(A_1, context);
        if among_var == 0 {
            break 'lab0;
        }
        env.bra = env.cursor;
        match among_var {
            1 => {
                env.slice_del();
            }
            2 => {
                if context.i_p1 > env.cursor {
                    break 'lab0;
                }
                let v_2 = env.limit - env.cursor;
                'lab1: loop {
                    if !env.eq_s_b(&"t") {
                        break 'lab1;
                    }
                    if context.i_p1 > env.cursor {
                        break 'lab1;
                    }
                    break 'lab0;
                }
                env.cursor = env.limit - v_2;
                if !r_C(env, context) {
                    break 'lab0;
                }
                env.slice_del();
            }
            3 => {
                if context.i_p1 > env.cursor {
                    break 'lab0;
                }
                env.slice_from("ie");
            }
            4 => {
                'lab2: loop {
                    let v_3 = env.limit - env.cursor;
                    'lab3: loop {
                        let v_4 = env.limit - env.cursor;
                        if !env.eq_s_b(&"ar") {
                            break 'lab3;
                        }
                        if context.i_p1 > env.cursor {
                            break 'lab3;
                        }
                        if !r_C(env, context) {
                            break 'lab3;
                        }
                        env.cursor = env.limit - v_4;
                        env.slice_del();
                        r_lengthen_V(env, context);
                        break 'lab2;
                    }
                    env.cursor = env.limit - v_3;
                    'lab4: loop {
                        let v_5 = env.limit - env.cursor;
                        if !env.eq_s_b(&"er") {
                            break 'lab4;
                        }
                        if context.i_p1 > env.cursor {
                            break 'lab4;
                        }
                        if !r_C(env, context) {
                            break 'lab4;
                        }
                        env.cursor = env.limit - v_5;
                        env.slice_del();
                        break 'lab2;
                    }
                    env.cursor = env.limit - v_3;
                    if context.i_p1 > env.cursor {
                        break 'lab0;
                    }
                    if !r_C(env, context) {
                        break 'lab0;
                    }
                    env.slice_from("e");
                    break 'lab2;
                }
            }
            5 => {
                if context.i_p1 > env.cursor {
                    break 'lab0;
                }
                env.slice_from("é");
            }
            6 => {
                if context.i_p1 > env.cursor {
                    break 'lab0;
                }
                if !r_V(env, context) {
                    break 'lab0;
                }
                env.slice_from("au");
            }
            7 => {
                'lab5: loop {
                    let v_6 = env.limit - env.cursor;
                    'lab6: loop {
                        if !env.eq_s_b(&"hed") {
                            break 'lab6;
                        }
                        if context.i_p1 > env.cursor {
                            break 'lab6;
                        }
                        env.bra = env.cursor;
                        env.slice_from("heid");
                        break 'lab5;
                    }
                    env.cursor = env.limit - v_6;
                    'lab7: loop {
                        if !env.eq_s_b(&"nd") {
                            break 'lab7;
                        }
                        env.slice_del();
                        break 'lab5;
                    }
                    env.cursor = env.limit - v_6;
                    'lab8: loop {
                        if !env.eq_s_b(&"d") {
                            break 'lab8;
                        }
                        if context.i_p1 > env.cursor {
                            break 'lab8;
                        }
                        if !r_C(env, context) {
                            break 'lab8;
                        }
                        env.bra = env.cursor;
                        env.slice_del();
                        break 'lab5;
                    }
                    env.cursor = env.limit - v_6;
                    'lab9: loop {
                        'lab10: loop {
                            'lab11: loop {
                                if !env.eq_s_b(&"i") {
                                    break 'lab11;
                                }
                                break 'lab10;
                            }
                            if !env.eq_s_b(&"j") {
                                break 'lab9;
                            }
                            break 'lab10;
                        }
                        if !r_V(env, context) {
                            break 'lab9;
                        }
                        env.slice_del();
                        break 'lab5;
                    }
                    env.cursor = env.limit - v_6;
                    if context.i_p1 > env.cursor {
                        break 'lab0;
                    }
                    if !r_C(env, context) {
                        break 'lab0;
                    }
                    env.slice_del();
                    r_lengthen_V(env, context);
                    break 'lab5;
                }
            }
            8 => {
                env.slice_from("nd");
            }
            _ => ()
        }
        b_stemmed = true;
        break 'lab0;
    }
    env.cursor = env.limit - v_1;
    let v_7 = env.limit - env.cursor;
    'lab12: loop {
        env.ket = env.cursor;
        if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 101 as u8) {
            break 'lab12;
        }

        among_var = env.find_among_b(A_2, context);
        if among_var == 0 {
            break 'lab12;
        }
        env.bra = env.cursor;
        match among_var {
            1 => {
                'lab13: loop {
                    let v_8 = env.limit - env.cursor;
                    'lab14: loop {
                        if !env.eq_s_b(&"'t") {
                            break 'lab14;
                        }
                        env.bra = env.cursor;
                        env.slice_del();
                        break 'lab13;
                    }
                    env.cursor = env.limit - v_8;
                    'lab15: loop {
                        if !env.eq_s_b(&"et") {
                            break 'lab15;
                        }
                        env.bra = env.cursor;
                        if context.i_p1 > env.cursor {
                            break 'lab15;
                        }
                        if !r_C(env, context) {
                            break 'lab15;
                        }
                        env.slice_del();
                        break 'lab13;
                    }
                    env.cursor = env.limit - v_8;
                    'lab16: loop {
                        if !env.eq_s_b(&"rnt") {
                            break 'lab16;
                        }
                        env.bra = env.cursor;
                        env.slice_from("rn");
                        break 'lab13;
                    }
                    env.cursor = env.limit - v_8;
                    'lab17: loop {
                        if !env.eq_s_b(&"t") {
                            break 'lab17;
                        }
                        env.bra = env.cursor;
                        if context.i_p1 > env.cursor {
                            break 'lab17;
                        }
                        let v_9 = env.limit - env.cursor;
                        if env.cursor <= env.limit_backward {
                            break 'lab17;
                        }
                        env.previous_char();
                        'lab18: loop {
                            'lab19: loop {
                                if !env.in_grouping_b(G_v, 97, 252) {
                                    break 'lab19;
                                }
                                break 'lab18;
                            }
                            if !env.eq_s_b(&"ij") {
                                break 'lab17;
                            }
                            break 'lab18;
                        }
                        env.cursor = env.limit - v_9;
                        env.slice_del();
                        break 'lab13;
                    }
                    env.cursor = env.limit - v_8;
                    'lab20: loop {
                        if !env.eq_s_b(&"ink") {
                            break 'lab20;
                        }
                        env.bra = env.cursor;
                        env.slice_from("ing");
                        break 'lab13;
                    }
                    env.cursor = env.limit - v_8;
                    'lab21: loop {
                        if !env.eq_s_b(&"mp") {
                            break 'lab21;
                        }
                        env.bra = env.cursor;
                        env.slice_from("m");
                        break 'lab13;
                    }
                    env.cursor = env.limit - v_8;
                    'lab22: loop {
                        if !env.eq_s_b(&"'") {
                            break 'lab22;
                        }
                        env.bra = env.cursor;
                        if context.i_p1 > env.cursor {
                            break 'lab22;
                        }
                        env.slice_del();
                        break 'lab13;
                    }
                    env.cursor = env.limit - v_8;
                    env.bra = env.cursor;
                    if context.i_p1 > env.cursor {
                        break 'lab12;
                    }
                    if !r_C(env, context) {
                        break 'lab12;
                    }
                    env.slice_del();
                    break 'lab13;
                }
            }
            2 => {
                if context.i_p1 > env.cursor {
                    break 'lab12;
                }
                env.slice_from("g");
            }
            3 => {
                if context.i_p1 > env.cursor {
                    break 'lab12;
                }
                env.slice_from("lijk");
            }
            4 => {
                if context.i_p1 > env.cursor {
                    break 'lab12;
                }
                env.slice_from("isch");
            }
            5 => {
                if context.i_p1 > env.cursor {
                    break 'lab12;
                }
                if !r_C(env, context) {
                    break 'lab12;
                }
                env.slice_del();
            }
            6 => {
                if context.i_p1 > env.cursor {
                    break 'lab12;
                }
                env.slice_from("t");
            }
            7 => {
                if context.i_p1 > env.cursor {
                    break 'lab12;
                }
                env.slice_from("s");
            }
            8 => {
                if context.i_p1 > env.cursor {
                    break 'lab12;
                }
                env.slice_from("r");
            }
            9 => {
                if context.i_p1 > env.cursor {
                    break 'lab12;
                }
                env.slice_del();
                let (bra, ket) = (env.cursor, env.cursor);
                env.insert(bra, ket, "l");
                r_lengthen_V(env, context);
            }
            10 => {
                if context.i_p1 > env.cursor {
                    break 'lab12;
                }
                if !r_C(env, context) {
                    break 'lab12;
                }
                env.slice_del();
                let (bra, ket) = (env.cursor, env.cursor);
                env.insert(bra, ket, "en");
                r_lengthen_V(env, context);
            }
            11 => {
                if context.i_p1 > env.cursor {
                    break 'lab12;
                }
                if !r_C(env, context) {
                    break 'lab12;
                }
                env.slice_from("ief");
            }
            _ => ()
        }
        b_stemmed = true;
        break 'lab12;
    }
    env.cursor = env.limit - v_7;
    let v_10 = env.limit - env.cursor;
    'lab23: loop {
        env.ket = env.cursor;
        if (env.cursor - 2 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((1316016 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
            break 'lab23;
        }

        among_var = env.find_among_b(A_3, context);
        if among_var == 0 {
            break 'lab23;
        }
        env.bra = env.cursor;
        match among_var {
            1 => {
                if context.i_p1 > env.cursor {
                    break 'lab23;
                }
                env.slice_from("eer");
            }
            2 => {
                if context.i_p1 > env.cursor {
                    break 'lab23;
                }
                env.slice_del();
                r_lengthen_V(env, context);
            }
            3 => {
                if context.i_p1 > env.cursor {
                    break 'lab23;
                }
                env.slice_del();
            }
            4 => {
                env.slice_from("r");
            }
            5 => {
                'lab24: loop {
                    let v_11 = env.limit - env.cursor;
                    'lab25: loop {
                        if !env.eq_s_b(&"ild") {
                            break 'lab25;
                        }
                        env.slice_from("er");
                        break 'lab24;
                    }
                    env.cursor = env.limit - v_11;
                    if context.i_p1 > env.cursor {
                        break 'lab23;
                    }
                    env.slice_del();
                    r_lengthen_V(env, context);
                    break 'lab24;
                }
            }
            6 => {
                if context.i_p1 > env.cursor {
                    break 'lab23;
                }
                if !r_C(env, context) {
                    break 'lab23;
                }
                env.slice_from("aar");
            }
            7 => {
                if context.i_p2 > env.cursor {
                    break 'lab23;
                }
                env.slice_del();
                let (bra, ket) = (env.cursor, env.cursor);
                env.insert(bra, ket, "f");
                r_lengthen_V(env, context);
            }
            8 => {
                if context.i_p2 > env.cursor {
                    break 'lab23;
                }
                env.slice_del();
                let (bra, ket) = (env.cursor, env.cursor);
                env.insert(bra, ket, "g");
                r_lengthen_V(env, context);
            }
            9 => {
                if context.i_p1 > env.cursor {
                    break 'lab23;
                }
                if !r_C(env, context) {
                    break 'lab23;
                }
                env.slice_from("t");
            }
            10 => {
                if context.i_p1 > env.cursor {
                    break 'lab23;
                }
                if !r_C(env, context) {
                    break 'lab23;
                }
                env.slice_from("d");
            }
            _ => ()
        }
        b_stemmed = true;
        break 'lab23;
    }
    env.cursor = env.limit - v_10;
    let v_12 = env.limit - env.cursor;
    'lab26: loop {
        'lab27: loop {
            let v_13 = env.limit - env.cursor;
            'lab28: loop {
                env.ket = env.cursor;
                if (env.cursor - 2 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((1315024 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
                    break 'lab28;
                }

                among_var = env.find_among_b(A_4, context);
                if among_var == 0 {
                    break 'lab28;
                }
                env.bra = env.cursor;
                match among_var {
                    1 => {
                        if context.i_p1 > env.cursor {
                            break 'lab28;
                        }
                        env.slice_from("ie");
                    }
                    2 => {
                        if context.i_p1 > env.cursor {
                            break 'lab28;
                        }
                        env.slice_from("eer");
                    }
                    3 => {
                        if context.i_p1 > env.cursor {
                            break 'lab28;
                        }
                        env.slice_del();
                    }
                    4 => {
                        if context.i_p1 > env.cursor {
                            break 'lab28;
                        }
                        if !r_V(env, context) {
                            break 'lab28;
                        }
                        env.slice_from("n");
                    }
                    5 => {
                        if context.i_p1 > env.cursor {
                            break 'lab28;
                        }
                        if !r_V(env, context) {
                            break 'lab28;
                        }
                        env.slice_from("l");
                    }
                    6 => {
                        if context.i_p1 > env.cursor {
                            break 'lab28;
                        }
                        if !r_V(env, context) {
                            break 'lab28;
                        }
                        env.slice_from("r");
                    }
                    7 => {
                        if context.i_p1 > env.cursor {
                            break 'lab28;
                        }
                        env.slice_from("teer");
                    }
                    8 => {
                        if context.i_p1 > env.cursor {
                            break 'lab28;
                        }
                        env.slice_from("lijk");
                    }
                    9 => {
                        if context.i_p1 > env.cursor {
                            break 'lab28;
                        }
                        if !r_C(env, context) {
                            break 'lab28;
                        }
                        env.slice_del();
                        r_lengthen_V(env, context);
                    }
                    _ => ()
                }
                break 'lab27;
            }
            env.cursor = env.limit - v_13;
            env.ket = env.cursor;
            if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((1310848 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
                break 'lab26;
            }

            if env.find_among_b(A_5, context) == 0 {
                break 'lab26;
            }
            env.bra = env.cursor;
            if context.i_p1 > env.cursor {
                break 'lab26;
            }
            let v_14 = env.limit - env.cursor;
            'lab29: loop {
                if !env.eq_s_b(&"inn") {
                    break 'lab29;
                }
                if env.cursor > env.limit_backward {
                    break 'lab29;
                }
                break 'lab26;
            }
            env.cursor = env.limit - v_14;
            if !r_C(env, context) {
                break 'lab26;
            }
            env.slice_del();
            r_lengthen_V(env, context);
            break 'lab27;
        }
        b_stemmed = true;
        break 'lab26;
    }
    env.cursor = env.limit - v_12;
    env.cursor = env.limit_backward;
    b_GE_removed = false;
    let v_15 = env.cursor;
    'lab30: loop {
        let v_16 = env.cursor;
        env.bra = env.cursor;
        if !env.eq_s(&"ge") {
            break 'lab30;
        }
        env.ket = env.cursor;
        let v_17 = env.cursor;
        if !env.hop(3) {
            break 'lab30;
        }
        env.cursor = v_17;
        let v_18 = env.cursor;
        'golab31: loop {
            let v_19 = env.cursor;
            'lab32: loop {
                'lab33: loop {
                    'lab34: loop {
                        if !env.eq_s(&"ij") {
                            break 'lab34;
                        }
                        break 'lab33;
                    }
                    if !env.in_grouping(G_v, 97, 252) {
                        break 'lab32;
                    }
                    break 'lab33;
                }
                break 'golab31;
            }
            env.cursor = v_19;
            if env.cursor >= env.limit {
                break 'lab30;
            }
            env.next_char();
        }
        'replab35: loop{
            let v_20 = env.cursor;
            'lab36: for _ in 0..1 {
                'lab37: loop {
                    'lab38: loop {
                        if !env.eq_s(&"ij") {
                            break 'lab38;
                        }
                        break 'lab37;
                    }
                    if !env.in_grouping(G_v, 97, 252) {
                        break 'lab36;
                    }
                    break 'lab37;
                }
                continue 'replab35;
            }
            env.cursor = v_20;
            break 'replab35;
        }
        if env.cursor >= env.limit {
            break 'lab30;
        }
        env.cursor = v_18;
        if (env.cursor + 2 >= env.limit || env.current.as_bytes()[(env.cursor + 2) as usize] as u8 >> 5 != 3 as u8 || ((1314818 as i32 >> (env.current.as_bytes()[(env.cursor + 2) as usize] as u8 & 0x1f)) & 1) == 0) {among_var = -1;}
        else {
            among_var = env.find_among(A_9, context);
        }
        match among_var {
            1 => {
                break 'lab30;
            }
            _ => ()
        }
        b_GE_removed = true;
        env.slice_del();
        let v_21 = env.cursor;
        'lab39: loop {
            env.bra = env.cursor;
            if (env.cursor + 1 >= env.limit || (env.current.as_bytes()[(env.cursor + 1) as usize] as u8 != 171 as u8 && env.current.as_bytes()[(env.cursor + 1) as usize] as u8 != 175 as u8)) {
                break 'lab39;
            }

            among_var = env.find_among(A_10, context);
            if among_var == 0 {
                break 'lab39;
            }
            env.ket = env.cursor;
            match among_var {
                1 => {
                    env.slice_from("e");
                }
                2 => {
                    env.slice_from("i");
                }
                _ => ()
            }
            break 'lab39;
        }
        env.cursor = v_21;
        env.cursor = v_16;
        r_measure(env, context);
        break 'lab30;
    }
    env.cursor = v_15;
    env.limit_backward = env.cursor;
    env.cursor = env.limit;
    let v_22 = env.limit - env.cursor;
    'lab40: loop {
        if !b_GE_removed {
            break 'lab40;
        }
        b_stemmed = true;
        if !r_Step_1c(env, context) {
            break 'lab40;
        }
        break 'lab40;
    }
    env.cursor = env.limit - v_22;
    env.cursor = env.limit_backward;
    b_GE_removed = false;
    let v_23 = env.cursor;
    'lab41: loop {
        let v_24 = env.cursor;
        if env.cursor >= env.limit {
            break 'lab41;
        }
        env.next_char();
        'golab42: loop {
            'lab43: loop {
                env.bra = env.cursor;
                if !env.eq_s(&"ge") {
                    break 'lab43;
                }
                env.ket = env.cursor;
                break 'golab42;
            }
            if env.cursor >= env.limit {
                break 'lab41;
            }
            env.next_char();
        }
        let v_25 = env.cursor;
        if !env.hop(3) {
            break 'lab41;
        }
        env.cursor = v_25;
        let v_26 = env.cursor;
        'golab44: loop {
            let v_27 = env.cursor;
            'lab45: loop {
                'lab46: loop {
                    'lab47: loop {
                        if !env.eq_s(&"ij") {
                            break 'lab47;
                        }
                        break 'lab46;
                    }
                    if !env.in_grouping(G_v, 97, 252) {
                        break 'lab45;
                    }
                    break 'lab46;
                }
                break 'golab44;
            }
            env.cursor = v_27;
            if env.cursor >= env.limit {
                break 'lab41;
            }
            env.next_char();
        }
        'replab48: loop{
            let v_28 = env.cursor;
            'lab49: for _ in 0..1 {
                'lab50: loop {
                    'lab51: loop {
                        if !env.eq_s(&"ij") {
                            break 'lab51;
                        }
                        break 'lab50;
                    }
                    if !env.in_grouping(G_v, 97, 252) {
                        break 'lab49;
                    }
                    break 'lab50;
                }
                continue 'replab48;
            }
            env.cursor = v_28;
            break 'replab48;
        }
        if env.cursor >= env.limit {
            break 'lab41;
        }
        env.cursor = v_26;
        b_GE_removed = true;
        env.slice_del();
        let v_29 = env.cursor;
        'lab52: loop {
            env.bra = env.cursor;
            if (env.cursor + 1 >= env.limit || (env.current.as_bytes()[(env.cursor + 1) as usize] as u8 != 171 as u8 && env.current.as_bytes()[(env.cursor + 1) as usize] as u8 != 175 as u8)) {
                break 'lab52;
            }

            among_var = env.find_among(A_11, context);
            if among_var == 0 {
                break 'lab52;
            }
            env.ket = env.cursor;
            match among_var {
                1 => {
                    env.slice_from("e");
                }
                2 => {
                    env.slice_from("i");
                }
                _ => ()
            }
            break 'lab52;
        }
        env.cursor = v_29;
        env.cursor = v_24;
        r_measure(env, context);
        break 'lab41;
    }
    env.cursor = v_23;
    env.limit_backward = env.cursor;
    env.cursor = env.limit;
    let v_30 = env.limit - env.cursor;
    'lab53: loop {
        if !b_GE_removed {
            break 'lab53;
        }
        b_stemmed = true;
        if !r_Step_1c(env, context) {
            break 'lab53;
        }
        break 'lab53;
    }
    env.cursor = env.limit - v_30;
    env.cursor = env.limit_backward;
    env.limit_backward = env.cursor;
    env.cursor = env.limit;
    let v_31 = env.limit - env.cursor;
    'lab54: loop {
        env.ket = env.cursor;
        if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 116 as u8) {
            break 'lab54;
        }

        among_var = env.find_among_b(A_6, context);
        if among_var == 0 {
            break 'lab54;
        }
        env.bra = env.cursor;
        match among_var {
            1 => {
                env.slice_from("k");
            }
            2 => {
                env.slice_from("f");
            }
            3 => {
                env.slice_from("p");
            }
            _ => ()
        }
        b_stemmed = true;
        break 'lab54;
    }
    env.cursor = env.limit - v_31;
    let v_32 = env.limit - env.cursor;
    'lab55: loop {
        if !b_stemmed {
            break 'lab55;
        }
        env.ket = env.cursor;
        if (env.cursor <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((98532828 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
            break 'lab55;
        }

        among_var = env.find_among_b(A_7, context);
        if among_var == 0 {
            break 'lab55;
        }
        env.bra = env.cursor;
        match among_var {
            1 => {
                env.slice_from("b");
            }
            2 => {
                env.slice_from("c");
            }
            3 => {
                env.slice_from("d");
            }
            4 => {
                env.slice_from("f");
            }
            5 => {
                env.slice_from("g");
            }
            6 => {
                env.slice_from("h");
            }
            7 => {
                env.slice_from("j");
            }
            8 => {
                env.slice_from("k");
            }
            9 => {
                env.slice_from("l");
            }
            10 => {
                env.slice_from("m");
            }
            11 => {
                let v_33 = env.limit - env.cursor;
                'lab56: loop {
                    if !env.eq_s_b(&"i") {
                        break 'lab56;
                    }
                    if env.cursor > env.limit_backward {
                        break 'lab56;
                    }
                    break 'lab55;
                }
                env.cursor = env.limit - v_33;
                env.slice_from("n");
            }
            12 => {
                env.slice_from("p");
            }
            13 => {
                env.slice_from("q");
            }
            14 => {
                env.slice_from("r");
            }
            15 => {
                env.slice_from("s");
            }
            16 => {
                env.slice_from("t");
            }
            17 => {
                env.slice_from("v");
            }
            18 => {
                env.slice_from("w");
            }
            19 => {
                env.slice_from("x");
            }
            20 => {
                env.slice_from("z");
            }
            _ => ()
        }
        break 'lab55;
    }
    env.cursor = env.limit - v_32;
    env.cursor = env.limit_backward;
    return true
}
