//! Generated from dutch_porter.sbl by Snowball 3.1.1 - https://snowballstem.org/

#![allow(non_snake_case)]
#![allow(non_upper_case_globals)]
#![allow(unused_mut)]
#![allow(unused_parens)]
#![allow(unused_variables)]
use crate::snowball::SnowballEnv;
use crate::snowball::Among;

#[derive(Clone)]
struct Context {
    i_p1: i32,
    b_e_found: bool,
}

static A_0: &'static [Among<Context>; 11] = &[
    Among("", -1, 6, None),
    Among("á", 0, 1, None),
    Among("ä", 0, 1, None),
    Among("é", 0, 2, None),
    Among("ë", 0, 2, None),
    Among("í", 0, 3, None),
    Among("ï", 0, 3, None),
    Among("ó", 0, 4, None),
    Among("ö", 0, 4, None),
    Among("ú", 0, 5, None),
    Among("ü", 0, 5, None),
];

static A_1: &'static [Among<Context>; 3] = &[
    Among("", -1, 3, None),
    Among("I", 0, 2, None),
    Among("Y", 0, 1, None),
];

static A_2: &'static [Among<Context>; 3] = &[
    Among("dd", -1, -1, None),
    Among("kk", -1, -1, None),
    Among("tt", -1, -1, None),
];

static A_3: &'static [Among<Context>; 5] = &[
    Among("ene", -1, 2, None),
    Among("se", -1, 3, None),
    Among("en", -1, 2, None),
    Among("heden", 2, 1, None),
    Among("s", -1, 3, None),
];

static A_4: &'static [Among<Context>; 6] = &[
    Among("end", -1, 1, None),
    Among("ig", -1, 2, None),
    Among("ing", -1, 1, None),
    Among("lijk", -1, 3, None),
    Among("baar", -1, 4, None),
    Among("bar", -1, 5, None),
];

static A_5: &'static [Among<Context>; 4] = &[
    Among("aa", -1, -1, None),
    Among("ee", -1, -1, None),
    Among("oo", -1, -1, None),
    Among("uu", -1, -1, None),
];

static G_v: &'static [u8; 17] = &[17, 65, 16, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128];

static G_v_I: &'static [u8; 20] = &[1, 0, 0, 17, 65, 16, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128];

static G_v_j: &'static [u8; 17] = &[17, 67, 16, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128];

fn r_undouble(env: &mut SnowballEnv, context: &mut Context) -> bool {
    let v_1 = env.limit - env.cursor;
    if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((1050640 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
        return false;
    }

    if env.find_among_b(A_2, context) == 0 {
        return false;
    }
    env.cursor = env.limit - v_1;
    env.ket = env.cursor;
    if env.cursor <= env.limit_backward {
        return false;
    }
    env.previous_char();
    env.bra = env.cursor;
    env.slice_del();
    return true
}

fn r_e_ending(env: &mut SnowballEnv, context: &mut Context) -> bool {
    context.b_e_found = false;
    env.ket = env.cursor;
    if !env.eq_s_b(&"e") {
        return false;
    }
    env.bra = env.cursor;
    if context.i_p1 > env.cursor {
        return false;
    }
    let v_1 = env.limit - env.cursor;
    if !env.out_grouping_b(G_v, 97, 232) {
        return false;
    }
    env.cursor = env.limit - v_1;
    env.slice_del();
    context.b_e_found = true;
    return r_undouble(env, context);
}

fn r_en_ending(env: &mut SnowballEnv, context: &mut Context) -> bool {
    if context.i_p1 > env.cursor {
        return false;
    }
    let v_1 = env.limit - env.cursor;
    if !env.out_grouping_b(G_v, 97, 232) {
        return false;
    }
    env.cursor = env.limit - v_1;
    'lab0: loop {
        if !env.eq_s_b(&"gem") {
            break 'lab0;
        }
        return false;
    }
    env.slice_del();
    return r_undouble(env, context);
}

pub fn stem(env: &mut SnowballEnv) -> bool {
    let mut context = &mut Context {
        i_p1: 0,
        b_e_found: false,
    };
    let mut among_var;
    let mut i_x : i32;
    let mut i_p2 : i32;
    let v_1 = env.cursor;
    'lab0: loop {
        let v_2 = env.cursor;
        'replab1: loop{
            let v_3 = env.cursor;
            'lab2: for _ in 0..1 {
                env.bra = env.cursor;
                if (env.cursor + 1 >= env.limit || env.current.as_bytes()[(env.cursor + 1) as usize] as u8 >> 5 != 5 as u8 || ((340306450 as i32 >> (env.current.as_bytes()[(env.cursor + 1) as usize] as u8 & 0x1f)) & 1) == 0) {among_var = 6;}
                else {
                    among_var = env.find_among(A_0, context);
                }
                env.ket = env.cursor;
                match among_var {
                    1 => {
                        env.slice_from("a");
                    }
                    2 => {
                        env.slice_from("e");
                    }
                    3 => {
                        env.slice_from("i");
                    }
                    4 => {
                        env.slice_from("o");
                    }
                    5 => {
                        env.slice_from("u");
                    }
                    6 => {
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
        let v_4 = env.cursor;
        'lab3: loop {
            env.bra = env.cursor;
            if !env.eq_s(&"y") {
                env.cursor = v_4;
                break 'lab3;
            }
            env.ket = env.cursor;
            env.slice_from("Y");
            break 'lab3;
        }
        'replab4: loop{
            let v_5 = env.cursor;
            'lab5: for _ in 0..1 {
                if !env.go_out_grouping(G_v, 97, 232) {
                    break 'lab5;
                }
                env.next_char();
                let v_6 = env.cursor;
                'lab6: loop {
                    env.bra = env.cursor;
                    'lab7: loop {
                        let v_7 = env.cursor;
                        'lab8: loop {
                            if !env.eq_s(&"i") {
                                break 'lab8;
                            }
                            env.ket = env.cursor;
                            let v_8 = env.cursor;
                            'lab9: loop {
                                if !env.in_grouping(G_v, 97, 232) {
                                    break 'lab9;
                                }
                                env.slice_from("I");
                                break 'lab9;
                            }
                            env.cursor = v_8;
                            break 'lab7;
                        }
                        env.cursor = v_7;
                        if !env.eq_s(&"y") {
                            env.cursor = v_6;
                            break 'lab6;
                        }
                        env.ket = env.cursor;
                        env.slice_from("Y");
                        break 'lab7;
                    }
                    break 'lab6;
                }
                continue 'replab4;
            }
            env.cursor = v_5;
            break 'replab4;
        }
        break 'lab0;
    }
    env.cursor = v_1;
    let v_9 = env.cursor;
    'lab10: loop {
        context.i_p1 = env.limit;
        i_p2 = env.limit;
        let v_10 = env.cursor;
        if !env.hop(3) {
            break 'lab10;
        }
        i_x = env.cursor;
        env.cursor = v_10;
        if !env.go_out_grouping(G_v, 97, 232) {
            break 'lab10;
        }
        env.next_char();
        if !env.go_in_grouping(G_v, 97, 232) {
            break 'lab10;
        }
        env.next_char();
        context.i_p1 = env.cursor;
        'lab11: loop {
            if context.i_p1 >= i_x {
                break 'lab11;
            }
            context.i_p1 = i_x;
            break 'lab11;
        }
        if !env.go_out_grouping(G_v, 97, 232) {
            break 'lab10;
        }
        env.next_char();
        if !env.go_in_grouping(G_v, 97, 232) {
            break 'lab10;
        }
        env.next_char();
        i_p2 = env.cursor;
        break 'lab10;
    }
    env.cursor = v_9;
    env.limit_backward = env.cursor;
    env.cursor = env.limit;
    'lab12: loop {
        let v_11 = env.limit - env.cursor;
        'lab13: loop {
            env.ket = env.cursor;
            if (env.cursor <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((540704 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
                break 'lab13;
            }

            among_var = env.find_among_b(A_3, context);
            if among_var == 0 {
                break 'lab13;
            }
            env.bra = env.cursor;
            match among_var {
                1 => {
                    if context.i_p1 > env.cursor {
                        break 'lab13;
                    }
                    env.slice_from("heid");
                }
                2 => {
                    if !r_en_ending(env, context) {
                        break 'lab13;
                    }
                }
                3 => {
                    if context.i_p1 > env.cursor {
                        break 'lab13;
                    }
                    if !env.out_grouping_b(G_v_j, 97, 232) {
                        break 'lab13;
                    }
                    env.slice_del();
                }
                _ => ()
            }
            break 'lab13;
        }
        env.cursor = env.limit - v_11;
        let v_12 = env.limit - env.cursor;
        r_e_ending(env, context);
        env.cursor = env.limit - v_12;
        let v_13 = env.limit - env.cursor;
        'lab14: loop {
            env.ket = env.cursor;
            if !env.eq_s_b(&"heid") {
                break 'lab14;
            }
            env.bra = env.cursor;
            if i_p2 > env.cursor {
                break 'lab14;
            }
            'lab15: loop {
                if !env.eq_s_b(&"c") {
                    break 'lab15;
                }
                break 'lab14;
            }
            env.slice_del();
            env.ket = env.cursor;
            if !env.eq_s_b(&"en") {
                break 'lab14;
            }
            env.bra = env.cursor;
            if !r_en_ending(env, context) {
                break 'lab14;
            }
            break 'lab14;
        }
        env.cursor = env.limit - v_13;
        let v_14 = env.limit - env.cursor;
        'lab16: loop {
            env.ket = env.cursor;
            if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((264336 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
                break 'lab16;
            }

            among_var = env.find_among_b(A_4, context);
            if among_var == 0 {
                break 'lab16;
            }
            env.bra = env.cursor;
            match among_var {
                1 => {
                    if i_p2 > env.cursor {
                        break 'lab16;
                    }
                    env.slice_del();
                    'lab17: loop {
                        let v_15 = env.limit - env.cursor;
                        'lab18: loop {
                            env.ket = env.cursor;
                            if !env.eq_s_b(&"ig") {
                                break 'lab18;
                            }
                            env.bra = env.cursor;
                            if i_p2 > env.cursor {
                                break 'lab18;
                            }
                            'lab19: loop {
                                if !env.eq_s_b(&"e") {
                                    break 'lab19;
                                }
                                break 'lab18;
                            }
                            env.slice_del();
                            break 'lab17;
                        }
                        env.cursor = env.limit - v_15;
                        if !r_undouble(env, context) {
                            break 'lab16;
                        }
                        break 'lab17;
                    }
                }
                2 => {
                    if i_p2 > env.cursor {
                        break 'lab16;
                    }
                    'lab20: loop {
                        if !env.eq_s_b(&"e") {
                            break 'lab20;
                        }
                        break 'lab16;
                    }
                    env.slice_del();
                }
                3 => {
                    if i_p2 > env.cursor {
                        break 'lab16;
                    }
                    env.slice_del();
                    if !r_e_ending(env, context) {
                        break 'lab16;
                    }
                }
                4 => {
                    if i_p2 > env.cursor {
                        break 'lab16;
                    }
                    env.slice_del();
                }
                5 => {
                    if i_p2 > env.cursor {
                        break 'lab16;
                    }
                    if !context.b_e_found {
                        break 'lab16;
                    }
                    env.slice_del();
                }
                _ => ()
            }
            break 'lab16;
        }
        env.cursor = env.limit - v_14;
        let v_16 = env.limit - env.cursor;
        'lab21: loop {
            if !env.out_grouping_b(G_v_I, 73, 232) {
                break 'lab21;
            }
            let v_17 = env.limit - env.cursor;
            if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((2129954 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
                break 'lab21;
            }

            if env.find_among_b(A_5, context) == 0 {
                break 'lab21;
            }
            if !env.out_grouping_b(G_v, 97, 232) {
                break 'lab21;
            }
            env.cursor = env.limit - v_17;
            env.ket = env.cursor;
            if env.cursor <= env.limit_backward {
                break 'lab21;
            }
            env.previous_char();
            env.bra = env.cursor;
            env.slice_del();
            break 'lab21;
        }
        env.cursor = env.limit - v_16;
        break 'lab12;
    }
    env.cursor = env.limit_backward;
    let v_18 = env.cursor;
    'lab22: loop {
        'replab23: loop{
            let v_19 = env.cursor;
            'lab24: for _ in 0..1 {
                env.bra = env.cursor;
                if (env.cursor >= env.limit || (env.current.as_bytes()[(env.cursor + 0) as usize] as u8 != 73 as u8 && env.current.as_bytes()[(env.cursor + 0) as usize] as u8 != 89 as u8)) {among_var = 3;}
                else {
                    among_var = env.find_among(A_1, context);
                }
                env.ket = env.cursor;
                match among_var {
                    1 => {
                        env.slice_from("y");
                    }
                    2 => {
                        env.slice_from("i");
                    }
                    3 => {
                        if env.cursor >= env.limit {
                            break 'lab24;
                        }
                        env.next_char();
                    }
                    _ => ()
                }
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
