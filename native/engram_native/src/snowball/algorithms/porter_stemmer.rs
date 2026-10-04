//! Generated from porter.sbl by Snowball 3.1.1 - https://snowballstem.org/

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

static A_0: &'static [Among<Context>; 4] = &[
    Among("s", -1, 3, None),
    Among("ies", 0, 2, None),
    Among("sses", 0, 1, None),
    Among("ss", 0, -1, None),
];

static A_1: &'static [Among<Context>; 13] = &[
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

static A_2: &'static [Among<Context>; 3] = &[
    Among("ed", -1, 2, None),
    Among("eed", 0, 1, None),
    Among("ing", -1, 2, None),
];

static A_3: &'static [Among<Context>; 20] = &[
    Among("anci", -1, 3, None),
    Among("enci", -1, 2, None),
    Among("abli", -1, 4, None),
    Among("eli", -1, 6, None),
    Among("alli", -1, 9, None),
    Among("ousli", -1, 11, None),
    Among("entli", -1, 5, None),
    Among("aliti", -1, 9, None),
    Among("biliti", -1, 13, None),
    Among("iviti", -1, 12, None),
    Among("tional", -1, 1, None),
    Among("ational", 10, 8, None),
    Among("alism", -1, 9, None),
    Among("ation", -1, 8, None),
    Among("ization", 13, 7, None),
    Among("izer", -1, 7, None),
    Among("ator", -1, 8, None),
    Among("iveness", -1, 12, None),
    Among("fulness", -1, 10, None),
    Among("ousness", -1, 11, None),
];

static A_4: &'static [Among<Context>; 7] = &[
    Among("icate", -1, 2, None),
    Among("ative", -1, 3, None),
    Among("alize", -1, 1, None),
    Among("iciti", -1, 2, None),
    Among("ical", -1, 2, None),
    Among("ful", -1, 3, None),
    Among("ness", -1, 3, None),
];

static A_5: &'static [Among<Context>; 19] = &[
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
    Among("ou", -1, 1, None),
];

static G_v: &'static [u8; 4] = &[17, 65, 16, 1];

static G_v_WXY: &'static [u8; 5] = &[1, 17, 65, 208, 1];

fn r_shortv(env: &mut SnowballEnv, context: &mut Context) -> bool {
    if !env.out_grouping_b(G_v_WXY, 89, 121) {
        return false;
    }
    if !env.in_grouping_b(G_v, 97, 121) {
        return false;
    }
    return env.out_grouping_b(G_v, 97, 121);
}

pub fn stem(env: &mut SnowballEnv) -> bool {
    let mut context = &mut Context {
    };
    let mut among_var;
    let mut b_Y_found : bool;
    let mut i_p2 : i32;
    let mut i_p1 : i32;
    b_Y_found = false;
    let v_1 = env.cursor;
    'lab0: loop {
        env.bra = env.cursor;
        if !env.eq_s(&"y") {
            break 'lab0;
        }
        env.ket = env.cursor;
        env.slice_from("Y");
        b_Y_found = true;
        break 'lab0;
    }
    env.cursor = v_1;
    let v_2 = env.cursor;
    'lab1: loop {
        'replab2: loop{
            let v_3 = env.cursor;
            'lab3: for _ in 0..1 {
                'golab4: loop {
                    let v_4 = env.cursor;
                    'lab5: loop {
                        if !env.in_grouping(G_v, 97, 121) {
                            break 'lab5;
                        }
                        env.bra = env.cursor;
                        if !env.eq_s(&"y") {
                            break 'lab5;
                        }
                        env.ket = env.cursor;
                        env.cursor = v_4;
                        break 'golab4;
                    }
                    env.cursor = v_4;
                    if env.cursor >= env.limit {
                        break 'lab3;
                    }
                    env.next_char();
                }
                env.slice_from("Y");
                b_Y_found = true;
                continue 'replab2;
            }
            env.cursor = v_3;
            break 'replab2;
        }
        break 'lab1;
    }
    env.cursor = v_2;
    i_p1 = env.limit;
    i_p2 = env.limit;
    let v_5 = env.cursor;
    'lab6: loop {
        if !env.go_out_grouping(G_v, 97, 121) {
            break 'lab6;
        }
        env.next_char();
        if !env.go_in_grouping(G_v, 97, 121) {
            break 'lab6;
        }
        env.next_char();
        i_p1 = env.cursor;
        if !env.go_out_grouping(G_v, 97, 121) {
            break 'lab6;
        }
        env.next_char();
        if !env.go_in_grouping(G_v, 97, 121) {
            break 'lab6;
        }
        env.next_char();
        i_p2 = env.cursor;
        break 'lab6;
    }
    env.cursor = v_5;
    env.limit_backward = env.cursor;
    env.cursor = env.limit;
    let v_6 = env.limit - env.cursor;
    'lab7: loop {
        env.ket = env.cursor;
        if (env.cursor <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 115 as u8) {
            break 'lab7;
        }

        among_var = env.find_among_b(A_0, context);
        if among_var == 0 {
            break 'lab7;
        }
        env.bra = env.cursor;
        match among_var {
            1 => {
                env.slice_from("ss");
            }
            2 => {
                env.slice_from("i");
            }
            3 => {
                env.slice_del();
            }
            _ => ()
        }
        break 'lab7;
    }
    env.cursor = env.limit - v_6;
    let v_7 = env.limit - env.cursor;
    'lab8: loop {
        env.ket = env.cursor;
        if (env.cursor - 1 <= env.limit_backward || (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 100 as u8 && env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 103 as u8)) {
            break 'lab8;
        }

        among_var = env.find_among_b(A_2, context);
        if among_var == 0 {
            break 'lab8;
        }
        env.bra = env.cursor;
        match among_var {
            1 => {
                if i_p1 > env.cursor {
                    break 'lab8;
                }
                env.slice_from("ee");
            }
            2 => {
                let v_8 = env.limit - env.cursor;
                if !env.go_out_grouping_b(G_v, 97, 121) {
                    break 'lab8;
                }
                env.previous_char();
                env.cursor = env.limit - v_8;
                env.slice_del();
                let v_9 = env.limit - env.cursor;
                if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((68514004 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {among_var = 3;}
                else {
                    among_var = env.find_among_b(A_1, context);
                }
                env.cursor = env.limit - v_9;
                match among_var {
                    1 => {
                        let c = env.cursor;
                        let (bra, ket) = (env.cursor, env.cursor);
                        env.insert(bra, ket, "e");
                        env.cursor = c;
                    }
                    2 => {
                        env.ket = env.cursor;
                        if env.cursor <= env.limit_backward {
                            break 'lab8;
                        }
                        env.previous_char();
                        env.bra = env.cursor;
                        env.slice_del();
                    }
                    3 => {
                        if env.cursor != i_p1 {
                            break 'lab8;
                        }
                        let v_10 = env.limit - env.cursor;
                        if !r_shortv(env, context) {
                            break 'lab8;
                        }
                        env.cursor = env.limit - v_10;
                        let c = env.cursor;
                        let (bra, ket) = (env.cursor, env.cursor);
                        env.insert(bra, ket, "e");
                        env.cursor = c;
                    }
                    _ => ()
                }
            }
            _ => ()
        }
        break 'lab8;
    }
    env.cursor = env.limit - v_7;
    let v_11 = env.limit - env.cursor;
    'lab9: loop {
        env.ket = env.cursor;
        'lab10: loop {
            'lab11: loop {
                if !env.eq_s_b(&"y") {
                    break 'lab11;
                }
                break 'lab10;
            }
            if !env.eq_s_b(&"Y") {
                break 'lab9;
            }
            break 'lab10;
        }
        env.bra = env.cursor;
        if !env.go_out_grouping_b(G_v, 97, 121) {
            break 'lab9;
        }
        env.previous_char();
        env.slice_from("i");
        break 'lab9;
    }
    env.cursor = env.limit - v_11;
    let v_12 = env.limit - env.cursor;
    'lab12: loop {
        env.ket = env.cursor;
        if (env.cursor - 2 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((815616 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
            break 'lab12;
        }

        among_var = env.find_among_b(A_3, context);
        if among_var == 0 {
            break 'lab12;
        }
        env.bra = env.cursor;
        if i_p1 > env.cursor {
            break 'lab12;
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
                env.slice_from("e");
            }
            7 => {
                env.slice_from("ize");
            }
            8 => {
                env.slice_from("ate");
            }
            9 => {
                env.slice_from("al");
            }
            10 => {
                env.slice_from("ful");
            }
            11 => {
                env.slice_from("ous");
            }
            12 => {
                env.slice_from("ive");
            }
            13 => {
                env.slice_from("ble");
            }
            _ => ()
        }
        break 'lab12;
    }
    env.cursor = env.limit - v_12;
    let v_13 = env.limit - env.cursor;
    'lab13: loop {
        env.ket = env.cursor;
        if (env.cursor - 2 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((528928 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
            break 'lab13;
        }

        among_var = env.find_among_b(A_4, context);
        if among_var == 0 {
            break 'lab13;
        }
        env.bra = env.cursor;
        if i_p1 > env.cursor {
            break 'lab13;
        }
        match among_var {
            1 => {
                env.slice_from("al");
            }
            2 => {
                env.slice_from("ic");
            }
            3 => {
                env.slice_del();
            }
            _ => ()
        }
        break 'lab13;
    }
    env.cursor = env.limit - v_13;
    let v_14 = env.limit - env.cursor;
    'lab14: loop {
        env.ket = env.cursor;
        if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((3961384 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
            break 'lab14;
        }

        among_var = env.find_among_b(A_5, context);
        if among_var == 0 {
            break 'lab14;
        }
        env.bra = env.cursor;
        if i_p2 > env.cursor {
            break 'lab14;
        }
        match among_var {
            1 => {
                env.slice_del();
            }
            2 => {
                'lab15: loop {
                    'lab16: loop {
                        if !env.eq_s_b(&"s") {
                            break 'lab16;
                        }
                        break 'lab15;
                    }
                    if !env.eq_s_b(&"t") {
                        break 'lab14;
                    }
                    break 'lab15;
                }
                env.slice_del();
            }
            _ => ()
        }
        break 'lab14;
    }
    env.cursor = env.limit - v_14;
    let v_15 = env.limit - env.cursor;
    'lab17: loop {
        env.ket = env.cursor;
        if !env.eq_s_b(&"e") {
            break 'lab17;
        }
        env.bra = env.cursor;
        'lab18: loop {
            'lab19: loop {
                if i_p2 > env.cursor {
                    break 'lab19;
                }
                break 'lab18;
            }
            if i_p1 > env.cursor {
                break 'lab17;
            }
            let v_16 = env.limit - env.cursor;
            'lab20: loop {
                if !r_shortv(env, context) {
                    break 'lab20;
                }
                break 'lab17;
            }
            env.cursor = env.limit - v_16;
            break 'lab18;
        }
        env.slice_del();
        break 'lab17;
    }
    env.cursor = env.limit - v_15;
    let v_17 = env.limit - env.cursor;
    'lab21: loop {
        env.ket = env.cursor;
        if !env.eq_s_b(&"l") {
            break 'lab21;
        }
        env.bra = env.cursor;
        if i_p2 > env.cursor {
            break 'lab21;
        }
        if !env.eq_s_b(&"l") {
            break 'lab21;
        }
        env.slice_del();
        break 'lab21;
    }
    env.cursor = env.limit - v_17;
    env.cursor = env.limit_backward;
    let v_18 = env.cursor;
    'lab22: loop {
        if !b_Y_found {
            break 'lab22;
        }
        'replab23: loop{
            let v_19 = env.cursor;
            'lab24: for _ in 0..1 {
                'golab25: loop {
                    let v_20 = env.cursor;
                    'lab26: loop {
                        env.bra = env.cursor;
                        if !env.eq_s(&"Y") {
                            break 'lab26;
                        }
                        env.ket = env.cursor;
                        env.cursor = v_20;
                        break 'golab25;
                    }
                    env.cursor = v_20;
                    if env.cursor >= env.limit {
                        break 'lab24;
                    }
                    env.next_char();
                }
                env.slice_from("y");
                continue 'replab23;
            }
            env.cursor = v_19;
            break 'replab23;
        }
        break 'lab22;
    }
    env.cursor = v_18;
    return true
}
