//! Generated from english.sbl by Snowball 3.1.1 - https://snowballstem.org/

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

static A_0: &'static [Among<Context>; 9] = &[
    Among("arsen", -1, -1, None),
    Among("commun", -1, -1, None),
    Among("emerg", -1, -1, None),
    Among("gener", -1, -1, None),
    Among("inter", -1, -1, None),
    Among("later", -1, -1, None),
    Among("organ", -1, -1, None),
    Among("past", -1, -1, None),
    Among("univers", -1, -1, None),
];

static A_1: &'static [Among<Context>; 3] = &[
    Among("'", -1, 1, None),
    Among("'s'", 0, 1, None),
    Among("'s", -1, 1, None),
];

static A_2: &'static [Among<Context>; 6] = &[
    Among("ied", -1, 2, None),
    Among("s", -1, 3, None),
    Among("ies", 1, 2, None),
    Among("sses", 1, 1, None),
    Among("ss", 1, -1, None),
    Among("us", 1, -1, None),
];

static A_3: &'static [Among<Context>; 3] = &[
    Among("succ", -1, 1, None),
    Among("proc", -1, 1, None),
    Among("exc", -1, 1, None),
];

static A_4: &'static [Among<Context>; 7] = &[
    Among("even", -1, 2, None),
    Among("cann", -1, 2, None),
    Among("inn", -1, 2, None),
    Among("earr", -1, 2, None),
    Among("herr", -1, 2, None),
    Among("out", -1, 2, None),
    Among("y", -1, 1, None),
];

static A_5: &'static [Among<Context>; 7] = &[
    Among("", -1, -1, None),
    Among("ed", 0, 2, None),
    Among("eed", 1, 1, None),
    Among("ing", 0, 3, None),
    Among("edly", 0, 2, None),
    Among("eedly", 4, 1, None),
    Among("ingly", 0, 2, None),
];

static A_6: &'static [Among<Context>; 13] = &[
    Among("", -1, 3, None),
    Among("bb", 0, 2, None),
    Among("dd", 0, 2, None),
    Among("ff", 0, 2, None),
    Among("gg", 0, 2, None),
    Among("bl", 0, 1, None),
    Among("mm", 0, 2, None),
    Among("nn", 0, 2, None),
    Among("pp", 0, 2, None),
    Among("rr", 0, 2, None),
    Among("at", 0, 1, None),
    Among("tt", 0, 2, None),
    Among("iz", 0, 1, None),
];

static A_7: &'static [Among<Context>; 25] = &[
    Among("anci", -1, 3, None),
    Among("enci", -1, 2, None),
    Among("ogi", -1, 14, None),
    Among("li", -1, 16, None),
    Among("bli", 3, 12, None),
    Among("abli", 4, 4, None),
    Among("alli", 3, 8, None),
    Among("fulli", 3, 9, None),
    Among("lessli", 3, 15, None),
    Among("ousli", 3, 10, None),
    Among("entli", 3, 5, None),
    Among("aliti", -1, 8, None),
    Among("biliti", -1, 12, None),
    Among("iviti", -1, 11, None),
    Among("tional", -1, 1, None),
    Among("ational", 14, 7, None),
    Among("alism", -1, 8, None),
    Among("ation", -1, 7, None),
    Among("ization", 17, 6, None),
    Among("izer", -1, 6, None),
    Among("ator", -1, 7, None),
    Among("iveness", -1, 11, None),
    Among("fulness", -1, 9, None),
    Among("ousness", -1, 10, None),
    Among("ogist", -1, 13, None),
];

static A_8: &'static [Among<Context>; 9] = &[
    Among("icate", -1, 4, None),
    Among("ative", -1, 6, None),
    Among("alize", -1, 3, None),
    Among("iciti", -1, 4, None),
    Among("ical", -1, 4, None),
    Among("tional", -1, 1, None),
    Among("ational", 5, 2, None),
    Among("ful", -1, 5, None),
    Among("ness", -1, 5, None),
];

static A_9: &'static [Among<Context>; 18] = &[
    Among("ic", -1, 1, None),
    Among("ance", -1, 1, None),
    Among("ence", -1, 1, None),
    Among("able", -1, 1, None),
    Among("ible", -1, 1, None),
    Among("ate", -1, 1, None),
    Among("ive", -1, 1, None),
    Among("ize", -1, 1, None),
    Among("iti", -1, 1, None),
    Among("al", -1, 1, None),
    Among("ism", -1, 1, None),
    Among("ion", -1, 2, None),
    Among("er", -1, 1, None),
    Among("ous", -1, 1, None),
    Among("ant", -1, 1, None),
    Among("ent", -1, 1, None),
    Among("ment", 15, 1, None),
    Among("ement", 16, 1, None),
];

static A_10: &'static [Among<Context>; 2] = &[
    Among("e", -1, 1, None),
    Among("l", -1, 2, None),
];

static A_11: &'static [Among<Context>; 15] = &[
    Among("andes", -1, -1, None),
    Among("atlas", -1, -1, None),
    Among("bias", -1, -1, None),
    Among("cosmos", -1, -1, None),
    Among("early", -1, 6, None),
    Among("gently", -1, 4, None),
    Among("howe", -1, -1, None),
    Among("idly", -1, 3, None),
    Among("news", -1, -1, None),
    Among("only", -1, 7, None),
    Among("singly", -1, 8, None),
    Among("skies", -1, 2, None),
    Among("skis", -1, 1, None),
    Among("sky", -1, -1, None),
    Among("ugly", -1, 5, None),
];

static G_aeo: &'static [u8; 2] = &[17, 64];

static G_v: &'static [u8; 4] = &[17, 65, 16, 1];

static G_v_WXY: &'static [u8; 5] = &[1, 17, 65, 208, 1];

static G_valid_LI: &'static [u8; 3] = &[55, 141, 2];

fn r_shortv(env: &mut SnowballEnv, context: &mut Context) -> bool {
    'lab0: loop {
        let v_1 = env.limit - env.cursor;
        'lab1: loop {
            if !env.out_grouping_b(G_v_WXY, 89, 121) {
                break 'lab1;
            }
            if !env.in_grouping_b(G_v, 97, 121) {
                break 'lab1;
            }
            if !env.out_grouping_b(G_v, 97, 121) {
                break 'lab1;
            }
            break 'lab0;
        }
        env.cursor = env.limit - v_1;
        'lab2: loop {
            if !env.out_grouping_b(G_v, 97, 121) {
                break 'lab2;
            }
            if !env.in_grouping_b(G_v, 97, 121) {
                break 'lab2;
            }
            if env.cursor > env.limit_backward {
                break 'lab2;
            }
            break 'lab0;
        }
        env.cursor = env.limit - v_1;
        if !env.eq_s_b(&"past") {
            return false;
        }
        break 'lab0;
    }
    return true
}

pub fn stem(env: &mut SnowballEnv) -> bool {
    let mut context = &mut Context {
    };
    let mut among_var;
    let mut b_Y_found : bool;
    let mut i_p2 : i32;
    let mut i_p1 : i32;
    'lab0: loop {
        let v_1 = env.cursor;
        'lab1: loop {
            env.bra = env.cursor;
            if (env.cursor + 2 >= env.limit || env.current.as_bytes()[(env.cursor + 2) as usize] as u8 >> 5 != 3 as u8 || ((42750482 as i32 >> (env.current.as_bytes()[(env.cursor + 2) as usize] as u8 & 0x1f)) & 1) == 0) {
                break 'lab1;
            }

            among_var = env.find_among(A_11, context);
            if among_var == 0 {
                break 'lab1;
            }
            env.ket = env.cursor;
            if env.cursor < env.limit {
                break 'lab1;
            }
            match among_var {
                1 => {
                    env.slice_from("ski");
                }
                2 => {
                    env.slice_from("sky");
                }
                3 => {
                    env.slice_from("idl");
                }
                4 => {
                    env.slice_from("gentl");
                }
                5 => {
                    env.slice_from("ugli");
                }
                6 => {
                    env.slice_from("earli");
                }
                7 => {
                    env.slice_from("onli");
                }
                8 => {
                    env.slice_from("singl");
                }
                _ => ()
            }
            break 'lab0;
        }
        env.cursor = v_1;
        'lab2: loop {
            'lab3: loop {
                if !env.hop(3) {
                    break 'lab3;
                }
                break 'lab2;
            }
            break 'lab0;
        }
        env.cursor = v_1;
        'lab4: loop {
            b_Y_found = false;
            let v_2 = env.cursor;
            'lab5: loop {
                env.bra = env.cursor;
                if !env.eq_s(&"'") {
                    break 'lab5;
                }
                env.ket = env.cursor;
                env.slice_del();
                break 'lab5;
            }
            env.cursor = v_2;
            let v_3 = env.cursor;
            'lab6: loop {
                env.bra = env.cursor;
                if !env.eq_s(&"y") {
                    break 'lab6;
                }
                env.ket = env.cursor;
                env.slice_from("Y");
                b_Y_found = true;
                break 'lab6;
            }
            env.cursor = v_3;
            let v_4 = env.cursor;
            'lab7: loop {
                'replab8: loop{
                    let v_5 = env.cursor;
                    'lab9: for _ in 0..1 {
                        'golab10: loop {
                            let v_6 = env.cursor;
                            'lab11: loop {
                                if !env.in_grouping(G_v, 97, 121) {
                                    break 'lab11;
                                }
                                env.bra = env.cursor;
                                if !env.eq_s(&"y") {
                                    break 'lab11;
                                }
                                env.ket = env.cursor;
                                env.cursor = v_6;
                                break 'golab10;
                            }
                            env.cursor = v_6;
                            if env.cursor >= env.limit {
                                break 'lab9;
                            }
                            env.next_char();
                        }
                        env.slice_from("Y");
                        b_Y_found = true;
                        continue 'replab8;
                    }
                    env.cursor = v_5;
                    break 'replab8;
                }
                break 'lab7;
            }
            env.cursor = v_4;
            break 'lab4;
        }
        'lab12: loop {
            i_p1 = env.limit;
            i_p2 = env.limit;
            let v_7 = env.cursor;
            'lab13: loop {
                'lab14: loop {
                    let v_8 = env.cursor;
                    'lab15: loop {
                        if (env.cursor + 3 >= env.limit || env.current.as_bytes()[(env.cursor + 3) as usize] as u8 >> 5 != 3 as u8 || ((5513250 as i32 >> (env.current.as_bytes()[(env.cursor + 3) as usize] as u8 & 0x1f)) & 1) == 0) {
                            break 'lab15;
                        }

                        if env.find_among(A_0, context) == 0 {
                            break 'lab15;
                        }
                        break 'lab14;
                    }
                    env.cursor = v_8;
                    if !env.go_out_grouping(G_v, 97, 121) {
                        break 'lab13;
                    }
                    env.next_char();
                    if !env.go_in_grouping(G_v, 97, 121) {
                        break 'lab13;
                    }
                    env.next_char();
                    break 'lab14;
                }
                i_p1 = env.cursor;
                if !env.go_out_grouping(G_v, 97, 121) {
                    break 'lab13;
                }
                env.next_char();
                if !env.go_in_grouping(G_v, 97, 121) {
                    break 'lab13;
                }
                env.next_char();
                i_p2 = env.cursor;
                break 'lab13;
            }
            env.cursor = v_7;
            break 'lab12;
        }
        env.limit_backward = env.cursor;
        env.cursor = env.limit;
        let v_9 = env.limit - env.cursor;
        'lab16: loop {
            let v_10 = env.limit - env.cursor;
            'lab17: loop {
                env.ket = env.cursor;
                if (env.cursor <= env.limit_backward || (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 39 as u8 && env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 115 as u8)) {
                    env.cursor = env.limit - v_10;
                    break 'lab17;
                }

                if env.find_among_b(A_1, context) == 0 {
                    env.cursor = env.limit - v_10;
                    break 'lab17;
                }
                env.bra = env.cursor;
                env.slice_del();
                break 'lab17;
            }
            env.ket = env.cursor;
            if (env.cursor <= env.limit_backward || (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 100 as u8 && env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 115 as u8)) {
                break 'lab16;
            }

            among_var = env.find_among_b(A_2, context);
            if among_var == 0 {
                break 'lab16;
            }
            env.bra = env.cursor;
            match among_var {
                1 => {
                    env.slice_from("ss");
                }
                2 => {
                    'lab18: loop {
                        let v_11 = env.limit - env.cursor;
                        'lab19: loop {
                            if !env.hop_back(2) {
                                break 'lab19;
                            }
                            env.slice_from("i");
                            break 'lab18;
                        }
                        env.cursor = env.limit - v_11;
                        env.slice_from("ie");
                        break 'lab18;
                    }
                }
                3 => {
                    if env.cursor <= env.limit_backward {
                        break 'lab16;
                    }
                    env.previous_char();
                    if !env.go_out_grouping_b(G_v, 97, 121) {
                        break 'lab16;
                    }
                    env.previous_char();
                    env.slice_del();
                }
                _ => ()
            }
            break 'lab16;
        }
        env.cursor = env.limit - v_9;
        let v_12 = env.limit - env.cursor;
        'lab20: loop {
            env.ket = env.cursor;
            if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((33554576 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {among_var = -1;}
            else {
                among_var = env.find_among_b(A_5, context);
            }
            env.bra = env.cursor;
            'lab21: loop {
                let v_13 = env.limit - env.cursor;
                'lab22: loop {
                    match among_var {
                        1 => {
                            let v_14 = env.limit - env.cursor;
                            'lab23: loop {
                                if i_p1 > env.cursor {
                                    break 'lab23;
                                }
                                'lab24: loop {
                                    let v_15 = env.limit - env.cursor;
                                    'lab25: loop {
                                        if (env.cursor - 2 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 99 as u8) {
                                            break 'lab25;
                                        }

                                        if env.find_among_b(A_3, context) == 0 {
                                            break 'lab25;
                                        }
                                        if env.cursor > env.limit_backward {
                                            break 'lab25;
                                        }
                                        break 'lab24;
                                    }
                                    env.cursor = env.limit - v_15;
                                    env.slice_from("ee");
                                    break 'lab24;
                                }
                                break 'lab23;
                            }
                            env.cursor = env.limit - v_14;
                        }
                        2 => {
                            break 'lab22;
                        }
                        3 => {
                            if (env.cursor <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((34881536 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
                                break 'lab22;
                            }

                            among_var = env.find_among_b(A_4, context);
                            if among_var == 0 {
                                break 'lab22;
                            }
                            match among_var {
                                1 => {
                                    let v_16 = env.limit - env.cursor;
                                    if !env.out_grouping_b(G_v, 97, 121) {
                                        break 'lab22;
                                    }
                                    if env.cursor > env.limit_backward {
                                        break 'lab22;
                                    }
                                    env.cursor = env.limit - v_16;
                                    env.bra = env.cursor;
                                    env.slice_from("ie");
                                }
                                2 => {
                                    if env.cursor > env.limit_backward {
                                        break 'lab22;
                                    }
                                }
                                _ => ()
                            }
                        }
                        _ => ()
                    }
                    break 'lab21;
                }
                env.cursor = env.limit - v_13;
                let v_17 = env.limit - env.cursor;
                if !env.go_out_grouping_b(G_v, 97, 121) {
                    break 'lab20;
                }
                env.previous_char();
                env.cursor = env.limit - v_17;
                env.slice_del();
                env.ket = env.cursor;
                env.bra = env.cursor;
                let v_18 = env.limit - env.cursor;
                if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((68514004 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {among_var = 3;}
                else {
                    among_var = env.find_among_b(A_6, context);
                }
                match among_var {
                    1 => {
                        env.slice_from("e");
                        break 'lab20;
                    }
                    2 => {
                        let v_19 = env.limit - env.cursor;
                        'lab26: loop {
                            if !env.in_grouping_b(G_aeo, 97, 111) {
                                break 'lab26;
                            }
                            if env.cursor > env.limit_backward {
                                break 'lab26;
                            }
                            break 'lab20;
                        }
                        env.cursor = env.limit - v_19;
                    }
                    3 => {
                        if env.cursor != i_p1 {
                            break 'lab20;
                        }
                        let v_20 = env.limit - env.cursor;
                        if !r_shortv(env, context) {
                            break 'lab20;
                        }
                        env.cursor = env.limit - v_20;
                        env.slice_from("e");
                        break 'lab20;
                    }
                    _ => ()
                }
                env.cursor = env.limit - v_18;
                env.ket = env.cursor;
                if env.cursor <= env.limit_backward {
                    break 'lab20;
                }
                env.previous_char();
                env.bra = env.cursor;
                env.slice_del();
                break 'lab21;
            }
            break 'lab20;
        }
        env.cursor = env.limit - v_12;
        let v_21 = env.limit - env.cursor;
        'lab27: loop {
            env.ket = env.cursor;
            'lab28: loop {
                'lab29: loop {
                    if !env.eq_s_b(&"y") {
                        break 'lab29;
                    }
                    break 'lab28;
                }
                if !env.eq_s_b(&"Y") {
                    break 'lab27;
                }
                break 'lab28;
            }
            env.bra = env.cursor;
            if !env.out_grouping_b(G_v, 97, 121) {
                break 'lab27;
            }
            if env.cursor <= env.limit_backward {
                break 'lab27;
            }
            env.slice_from("i");
            break 'lab27;
        }
        env.cursor = env.limit - v_21;
        let v_22 = env.limit - env.cursor;
        'lab30: loop {
            env.ket = env.cursor;
            if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((1864192 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
                break 'lab30;
            }

            among_var = env.find_among_b(A_7, context);
            if among_var == 0 {
                break 'lab30;
            }
            env.bra = env.cursor;
            if i_p1 > env.cursor {
                break 'lab30;
            }
            match among_var {
                1 => {
                    env.slice_from("tion");
                }
                2 => {
                    env.slice_from("ence");
                }
                3 => {
                    env.slice_from("ance");
                }
                4 => {
                    env.slice_from("able");
                }
                5 => {
                    env.slice_from("ent");
                }
                6 => {
                    env.slice_from("ize");
                }
                7 => {
                    env.slice_from("ate");
                }
                8 => {
                    env.slice_from("al");
                }
                9 => {
                    env.slice_from("ful");
                }
                10 => {
                    env.slice_from("ous");
                }
                11 => {
                    env.slice_from("ive");
                }
                12 => {
                    env.slice_from("ble");
                }
                13 => {
                    env.slice_from("og");
                }
                14 => {
                    if !env.eq_s_b(&"l") {
                        break 'lab30;
                    }
                    env.slice_from("og");
                }
                15 => {
                    env.slice_from("less");
                }
                16 => {
                    if !env.in_grouping_b(G_valid_LI, 99, 116) {
                        break 'lab30;
                    }
                    env.slice_del();
                }
                _ => ()
            }
            break 'lab30;
        }
        env.cursor = env.limit - v_22;
        let v_23 = env.limit - env.cursor;
        'lab31: loop {
            env.ket = env.cursor;
            if (env.cursor - 2 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((528928 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
                break 'lab31;
            }

            among_var = env.find_among_b(A_8, context);
            if among_var == 0 {
                break 'lab31;
            }
            env.bra = env.cursor;
            if i_p1 > env.cursor {
                break 'lab31;
            }
            match among_var {
                1 => {
                    env.slice_from("tion");
                }
                2 => {
                    env.slice_from("ate");
                }
                3 => {
                    env.slice_from("al");
                }
                4 => {
                    env.slice_from("ic");
                }
                5 => {
                    env.slice_del();
                }
                6 => {
                    if i_p2 > env.cursor {
                        break 'lab31;
                    }
                    env.slice_del();
                }
                _ => ()
            }
            break 'lab31;
        }
        env.cursor = env.limit - v_23;
        let v_24 = env.limit - env.cursor;
        'lab32: loop {
            env.ket = env.cursor;
            if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((1864232 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
                break 'lab32;
            }

            among_var = env.find_among_b(A_9, context);
            if among_var == 0 {
                break 'lab32;
            }
            env.bra = env.cursor;
            if i_p2 > env.cursor {
                break 'lab32;
            }
            match among_var {
                1 => {
                    env.slice_del();
                }
                2 => {
                    'lab33: loop {
                        'lab34: loop {
                            if !env.eq_s_b(&"s") {
                                break 'lab34;
                            }
                            break 'lab33;
                        }
                        if !env.eq_s_b(&"t") {
                            break 'lab32;
                        }
                        break 'lab33;
                    }
                    env.slice_del();
                }
                _ => ()
            }
            break 'lab32;
        }
        env.cursor = env.limit - v_24;
        let v_25 = env.limit - env.cursor;
        'lab35: loop {
            env.ket = env.cursor;
            if (env.cursor <= env.limit_backward || (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 101 as u8 && env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 108 as u8)) {
                break 'lab35;
            }

            among_var = env.find_among_b(A_10, context);
            if among_var == 0 {
                break 'lab35;
            }
            env.bra = env.cursor;
            match among_var {
                1 => {
                    'lab36: loop {
                        'lab37: loop {
                            if i_p2 > env.cursor {
                                break 'lab37;
                            }
                            break 'lab36;
                        }
                        if i_p1 > env.cursor {
                            break 'lab35;
                        }
                        let v_26 = env.limit - env.cursor;
                        'lab38: loop {
                            if !r_shortv(env, context) {
                                break 'lab38;
                            }
                            break 'lab35;
                        }
                        env.cursor = env.limit - v_26;
                        break 'lab36;
                    }
                    env.slice_del();
                }
                2 => {
                    if i_p2 > env.cursor {
                        break 'lab35;
                    }
                    if !env.eq_s_b(&"l") {
                        break 'lab35;
                    }
                    env.slice_del();
                }
                _ => ()
            }
            break 'lab35;
        }
        env.cursor = env.limit - v_25;
        env.cursor = env.limit_backward;
        let v_27 = env.cursor;
        'lab39: loop {
            if !b_Y_found {
                break 'lab39;
            }
            'replab40: loop{
                let v_28 = env.cursor;
                'lab41: for _ in 0..1 {
                    'golab42: loop {
                        let v_29 = env.cursor;
                        'lab43: loop {
                            env.bra = env.cursor;
                            if !env.eq_s(&"Y") {
                                break 'lab43;
                            }
                            env.ket = env.cursor;
                            env.cursor = v_29;
                            break 'golab42;
                        }
                        env.cursor = v_29;
                        if env.cursor >= env.limit {
                            break 'lab41;
                        }
                        env.next_char();
                    }
                    env.slice_from("y");
                    continue 'replab40;
                }
                env.cursor = v_28;
                break 'replab40;
            }
            break 'lab39;
        }
        env.cursor = v_27;
        break 'lab0;
    }
    return true
}
