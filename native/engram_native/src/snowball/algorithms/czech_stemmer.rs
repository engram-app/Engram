//! Generated from czech.sbl by Snowball 3.1.1 - https://snowballstem.org/

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

static A_0: &'static [Among<Context>; 5] = &[
    Among("c", -1, 1, None),
    Among("nc", 0, -1, None),
    Among("ínc", 1, 2, None),
    Among("avc", 0, -1, None),
    Among("ovc", 0, -1, None),
];

static A_1: &'static [Among<Context>; 13] = &[
    Among("c", -1, 1, None),
    Among("nc", 0, -1, None),
    Among("ínc", 1, 2, None),
    Among("avc", 0, -1, None),
    Among("ovc", 0, -1, None),
    Among("čt", -1, 3, None),
    Among("št", -1, 4, None),
    Among("dešt", 6, -1, None),
    Among("lešt", 6, -1, None),
    Among("išt", 6, -1, None),
    Among("poušt", 6, -1, None),
    Among("ášt", 6, -1, None),
    Among("íšt", 6, -1, None),
];

static A_2: &'static [Among<Context>; 3] = &[
    Among("in", -1, 2, None),
    Among("ov", -1, 1, None),
    Among("ův", -1, 1, None),
];

static A_3: &'static [Among<Context>; 9] = &[
    Among("", -1, 2, None),
    Among("l", 0, 1, None),
    Among("tl", 1, 2, None),
    Among("s", 0, 1, None),
    Among("es", 3, 2, None),
    Among("č", 0, 1, None),
    Among("eč", 5, 2, None),
    Among("ř", 0, 1, None),
    Among("ž", 0, 1, None),
];

static A_4: &'static [Among<Context>; 3] = &[
    Among("obl", -1, -1, None),
    Among("sn", -1, -1, None),
    Among("dot", -1, -1, None),
];

static A_5: &'static [Among<Context>; 5] = &[
    Among("uc", -1, -1, None),
    Among("h", -1, -1, None),
    Among("ok", -1, -1, None),
    Among("kar", -1, -1, None),
    Among("č", -1, -1, None),
];

static A_6: &'static [Among<Context>; 58] = &[
    Among("a", -1, 1, None),
    Among("ama", 0, 1, None),
    Among("ata", 0, 1, None),
    Among("eb", -1, 4, None),
    Among("ec", -1, 5, None),
    Among("e", -1, 2, None),
    Among("ete", 5, 3, None),
    Among("ěte", 5, 1, None),
    Among("ech", -1, 2, None),
    Among("atech", 8, 1, None),
    Among("ách", -1, 1, None),
    Among("ích", -1, 12, None),
    Among("ých", -1, 1, None),
    Among("i", -1, 12, None),
    Among("mi", 13, 1, None),
    Among("ami", 14, 1, None),
    Among("emi", 14, 2, None),
    Among("ěmi", 14, 1, None),
    Among("ťmi", 14, 11, None),
    Among("ími", 14, 12, None),
    Among("ými", 14, 1, None),
    Among("eti", 13, 3, None),
    Among("ěti", 13, 1, None),
    Among("ovi", 13, 1, None),
    Among("ek", -1, 6, None),
    Among("ěk", -1, 7, None),
    Among("em", -1, 2, None),
    Among("etem", 26, 3, None),
    Among("ětem", 26, 1, None),
    Among("ěm", -1, 1, None),
    Among("ám", -1, 1, None),
    Among("ém", -1, 1, None),
    Among("ím", -1, 12, None),
    Among("ům", -1, 1, None),
    Among("atům", 33, 1, None),
    Among("ým", -1, 1, None),
    Among("o", -1, 1, None),
    Among("ého", 36, 1, None),
    Among("ího", 36, 12, None),
    Among("us", -1, 1, None),
    Among("at", -1, 1, None),
    Among("et", -1, 9, None),
    Among("u", -1, 1, None),
    Among("ému", 42, 1, None),
    Among("ímu", 42, 12, None),
    Among("ou", 42, 1, None),
    Among("ev", -1, 10, None),
    Among("y", -1, 1, None),
    Among("aty", 47, 1, None),
    Among("eň", -1, 8, None),
    Among("ě", -1, 1, None),
    Among("á", -1, 1, None),
    Among("ť", -1, 11, None),
    Among("é", -1, 1, None),
    Among("ové", 53, 1, None),
    Among("í", -1, 12, None),
    Among("ů", -1, 1, None),
    Among("ý", -1, 1, None),
];

static G_v: &'static [u8; 34] = &[17, 65, 16, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 17, 4, 18, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 64];

static G_v_or_syllabic_c: &'static [u8; 34] = &[17, 73, 18, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 17, 4, 18, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 64];

static G_ev_ending: &'static [u8; 3] = &[73, 20, 4];

static G_env_ending: &'static [u8; 36] = &[71, 66, 23, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 16];

fn r_palatalise_e(env: &mut SnowballEnv, context: &mut Context) -> bool {
    let mut among_var;
    env.ket = env.cursor;
    if (env.cursor <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 99 as u8) {
        return false;
    }

    among_var = env.find_among_b(A_0, context);
    if among_var == 0 {
        return false;
    }
    env.bra = env.cursor;
    match among_var {
        1 => {
            env.slice_from("k");
        }
        2 => {
            env.slice_from("ínk");
        }
        _ => ()
    }
    return true
}

fn r_palatalise_i(env: &mut SnowballEnv, context: &mut Context) -> bool {
    let mut among_var;
    env.ket = env.cursor;
    if (env.cursor <= env.limit_backward || (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 99 as u8 && env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 116 as u8)) {
        return false;
    }

    among_var = env.find_among_b(A_1, context);
    if among_var == 0 {
        return false;
    }
    env.bra = env.cursor;
    match among_var {
        1 => {
            env.slice_from("k");
        }
        2 => {
            env.slice_from("ínk");
        }
        3 => {
            env.slice_from("ck");
        }
        4 => {
            env.slice_from("sk");
        }
        _ => ()
    }
    return true
}

pub fn stem(env: &mut SnowballEnv) -> bool {
    let mut context = &mut Context {
    };
    let mut among_var;
    let mut i_x : i32;
    let mut i_p1 : i32;
    let v_1 = env.cursor;
    if !env.hop(3) {
        return false;
    }
    i_x = env.cursor;
    env.cursor = v_1;
    i_p1 = env.limit;
    let v_2 = env.cursor;
    'lab0: loop {
        'lab1: loop {
            'lab2: loop {
                if !env.in_grouping(G_v, 97, 367) {
                    break 'lab2;
                }
                break 'lab1;
            }
            if env.cursor >= env.limit {
                break 'lab0;
            }
            env.next_char();
            if !env.go_out_grouping(G_v_or_syllabic_c, 97, 367) {
                break 'lab0;
            }
            env.next_char();
            break 'lab1;
        }
        if !env.go_in_grouping(G_v, 97, 367) {
            break 'lab0;
        }
        env.next_char();
        i_p1 = env.cursor;
        'lab3: loop {
            if i_p1 >= i_x {
                break 'lab3;
            }
            i_p1 = i_x;
            break 'lab3;
        }
        break 'lab0;
    }
    env.cursor = v_2;
    env.limit_backward = env.cursor;
    env.cursor = env.limit;
    let v_3 = env.limit - env.cursor;
    'lab4: loop {
        if env.cursor < i_p1 {
            break 'lab4;
        }
        let v_4 = env.limit_backward;
        env.limit_backward = i_p1;
        env.ket = env.cursor;
        among_var = env.find_among_b(A_6, context);
        if among_var == 0 {
            env.limit_backward = v_4;
            break 'lab4;
        }
        env.bra = env.cursor;
        env.limit_backward = v_4;
        match among_var {
            1 => {
                env.slice_del();
            }
            2 => {
                env.slice_del();
                let v_5 = env.limit - env.cursor;
                'lab5: loop {
                    if !r_palatalise_e(env, context) {
                        env.cursor = env.limit - v_5;
                        break 'lab5;
                    }
                    break 'lab5;
                }
            }
            3 => {
                among_var = env.find_among_b(A_3, context);
                match among_var {
                    1 => {
                        env.slice_del();
                    }
                    2 => {
                        env.slice_from("et");
                    }
                    _ => ()
                }
            }
            4 => {
                let v_6 = env.limit - env.cursor;
                if !env.out_grouping_b(G_v, 97, 367) {
                    break 'lab4;
                }
                env.cursor = env.limit - v_6;
                'lab6: loop {
                    if !env.eq_s_b(&"tř") {
                        break 'lab6;
                    }
                    break 'lab4;
                }
                env.slice_from("b");
            }
            5 => {
                let v_7 = env.limit - env.cursor;
                if !env.out_grouping_b(G_v, 97, 367) {
                    break 'lab4;
                }
                env.cursor = env.limit - v_7;
                env.slice_del();
                let (bra, ket) = (env.cursor, env.cursor);
                env.insert(bra, ket, "c");
                let v_8 = env.limit - env.cursor;
                'lab7: loop {
                    if !r_palatalise_e(env, context) {
                        env.cursor = env.limit - v_8;
                        break 'lab7;
                    }
                    break 'lab7;
                }
            }
            6 => {
                let v_9 = env.limit - env.cursor;
                if !env.out_grouping_b(G_v, 97, 367) {
                    break 'lab4;
                }
                env.cursor = env.limit - v_9;
                let v_10 = env.limit - env.cursor;
                'lab8: loop {
                    if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((1069056 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
                        break 'lab8;
                    }

                    if env.find_among_b(A_4, context) == 0 {
                        break 'lab8;
                    }
                    break 'lab4;
                }
                env.cursor = env.limit - v_10;
                env.slice_from("k");
            }
            7 => {
                if !env.eq_s_b(&"n") {
                    break 'lab4;
                }
                env.bra = env.cursor;
                env.slice_from("ňk");
            }
            8 => {
                let v_11 = env.limit - env.cursor;
                if !env.in_grouping_b(G_env_ending, 98, 382) {
                    break 'lab4;
                }
                env.cursor = env.limit - v_11;
                env.slice_from("n");
            }
            9 => {
                if env.find_among_b(A_5, context) == 0 {
                    break 'lab4;
                }
                env.slice_from("t");
            }
            10 => {
                if !env.in_grouping_b(G_ev_ending, 104, 122) {
                    break 'lab4;
                }
                env.slice_from("v");
            }
            11 => {
                env.slice_from("t");
            }
            12 => {
                env.slice_del();
                let v_12 = env.limit - env.cursor;
                'lab9: loop {
                    if !r_palatalise_i(env, context) {
                        env.cursor = env.limit - v_12;
                        break 'lab9;
                    }
                    break 'lab9;
                }
            }
            _ => ()
        }
        break 'lab4;
    }
    env.cursor = env.limit - v_3;
    let v_13 = env.limit - env.cursor;
    'lab10: loop {
        env.ket = env.cursor;
        if (env.cursor - 1 <= env.limit_backward || (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 110 as u8 && env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 118 as u8)) {
            break 'lab10;
        }

        among_var = env.find_among_b(A_2, context);
        if among_var == 0 {
            break 'lab10;
        }
        env.bra = env.cursor;
        if i_p1 > env.cursor {
            break 'lab10;
        }
        match among_var {
            1 => {
                env.slice_del();
            }
            2 => {
                env.slice_del();
                let v_14 = env.limit - env.cursor;
                'lab11: loop {
                    if !r_palatalise_i(env, context) {
                        env.cursor = env.limit - v_14;
                        break 'lab11;
                    }
                    break 'lab11;
                }
            }
            _ => ()
        }
        break 'lab10;
    }
    env.cursor = env.limit - v_13;
    env.cursor = env.limit_backward;
    return true
}
