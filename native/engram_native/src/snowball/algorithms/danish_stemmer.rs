//! Generated from danish.sbl by Snowball 3.1.1 - https://snowballstem.org/

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
    S_ch: String,
}

static A_0: &'static [Among<Context>; 32] = &[
    Among("hed", -1, 1, None),
    Among("ethed", 0, 1, None),
    Among("ered", -1, 1, None),
    Among("e", -1, 1, None),
    Among("erede", 3, 1, None),
    Among("ende", 3, 1, None),
    Among("erende", 5, 1, None),
    Among("ene", 3, 1, None),
    Among("erne", 3, 1, None),
    Among("ere", 3, 1, None),
    Among("en", -1, 1, None),
    Among("heden", 10, 1, None),
    Among("eren", 10, 1, None),
    Among("er", -1, 1, None),
    Among("heder", 13, 1, None),
    Among("erer", 13, 1, None),
    Among("s", -1, 2, None),
    Among("heds", 16, 1, None),
    Among("es", 16, 1, None),
    Among("endes", 18, 1, None),
    Among("erendes", 19, 1, None),
    Among("enes", 18, 1, None),
    Among("ernes", 18, 1, None),
    Among("eres", 18, 1, None),
    Among("ens", 16, 1, None),
    Among("hedens", 24, 1, None),
    Among("erens", 24, 1, None),
    Among("ers", 16, 1, None),
    Among("ets", 16, 1, None),
    Among("erets", 28, 1, None),
    Among("et", -1, 1, None),
    Among("eret", 30, 1, None),
];

static A_1: &'static [Among<Context>; 4] = &[
    Among("gd", -1, -1, None),
    Among("dt", -1, -1, None),
    Among("gt", -1, -1, None),
    Among("kt", -1, -1, None),
];

static A_2: &'static [Among<Context>; 5] = &[
    Among("ig", -1, 1, None),
    Among("lig", 0, 1, None),
    Among("elig", 1, 1, None),
    Among("els", -1, 1, None),
    Among("løst", -1, 2, None),
];

static G_c: &'static [u8; 4] = &[119, 223, 119, 1];

static G_v: &'static [u8; 19] = &[17, 65, 16, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 48, 0, 128];

static G_s_ending: &'static [u8; 17] = &[239, 254, 42, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 16];

fn r_consonant_pair(env: &mut SnowballEnv, context: &mut Context) -> bool {
    let v_1 = env.limit - env.cursor;
    if env.cursor < context.i_p1 {
        return false;
    }
    let v_2 = env.limit_backward;
    env.limit_backward = context.i_p1;
    env.ket = env.cursor;
    if (env.cursor - 1 <= env.limit_backward || (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 100 as u8 && env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 116 as u8)) {
        env.limit_backward = v_2;
        return false;
    }

    if env.find_among_b(A_1, context) == 0 {
        env.limit_backward = v_2;
        return false;
    }
    env.bra = env.cursor;
    env.limit_backward = v_2;
    env.cursor = env.limit - v_1;
    if env.cursor <= env.limit_backward {
        return false;
    }
    env.previous_char();
    env.bra = env.cursor;
    env.slice_del();
    return true
}

pub fn stem(env: &mut SnowballEnv) -> bool {
    let mut context = &mut Context {
        i_p1: 0,
        S_ch: String::new(),
    };
    let mut among_var;
    let mut i_x : i32;
    let v_1 = env.cursor;
    'lab0: loop {
        context.i_p1 = env.limit;
        let v_2 = env.cursor;
        if !env.hop(3) {
            break 'lab0;
        }
        i_x = env.cursor;
        env.cursor = v_2;
        if !env.go_out_grouping(G_v, 97, 248) {
            break 'lab0;
        }
        env.next_char();
        if !env.go_in_grouping(G_v, 97, 248) {
            break 'lab0;
        }
        env.next_char();
        context.i_p1 = env.cursor;
        'lab1: loop {
            if context.i_p1 >= i_x {
                break 'lab1;
            }
            context.i_p1 = i_x;
            break 'lab1;
        }
        break 'lab0;
    }
    env.cursor = v_1;
    env.limit_backward = env.cursor;
    env.cursor = env.limit;
    let v_3 = env.limit - env.cursor;
    'lab2: loop {
        if env.cursor < context.i_p1 {
            break 'lab2;
        }
        let v_4 = env.limit_backward;
        env.limit_backward = context.i_p1;
        env.ket = env.cursor;
        if (env.cursor <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((1851440 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
            env.limit_backward = v_4;
            break 'lab2;
        }

        among_var = env.find_among_b(A_0, context);
        if among_var == 0 {
            env.limit_backward = v_4;
            break 'lab2;
        }
        env.bra = env.cursor;
        env.limit_backward = v_4;
        match among_var {
            1 => {
                env.slice_del();
            }
            2 => {
                if !env.in_grouping_b(G_s_ending, 97, 229) {
                    break 'lab2;
                }
                env.slice_del();
            }
            _ => ()
        }
        break 'lab2;
    }
    env.cursor = env.limit - v_3;
    let v_5 = env.limit - env.cursor;
    r_consonant_pair(env, context);
    env.cursor = env.limit - v_5;
    let v_6 = env.limit - env.cursor;
    'lab3: loop {
        let v_7 = env.limit - env.cursor;
        'lab4: loop {
            env.ket = env.cursor;
            if !env.eq_s_b(&"st") {
                break 'lab4;
            }
            env.bra = env.cursor;
            if !env.eq_s_b(&"ig") {
                break 'lab4;
            }
            env.slice_del();
            break 'lab4;
        }
        env.cursor = env.limit - v_7;
        if env.cursor < context.i_p1 {
            break 'lab3;
        }
        let v_8 = env.limit_backward;
        env.limit_backward = context.i_p1;
        env.ket = env.cursor;
        if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((1572992 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
            env.limit_backward = v_8;
            break 'lab3;
        }

        among_var = env.find_among_b(A_2, context);
        if among_var == 0 {
            env.limit_backward = v_8;
            break 'lab3;
        }
        env.bra = env.cursor;
        env.limit_backward = v_8;
        match among_var {
            1 => {
                env.slice_del();
                let v_9 = env.limit - env.cursor;
                r_consonant_pair(env, context);
                env.cursor = env.limit - v_9;
            }
            2 => {
                env.slice_from("løs");
            }
            _ => ()
        }
        break 'lab3;
    }
    env.cursor = env.limit - v_6;
    let v_10 = env.limit - env.cursor;
    'lab5: loop {
        if env.cursor < context.i_p1 {
            break 'lab5;
        }
        let v_11 = env.limit_backward;
        env.limit_backward = context.i_p1;
        env.ket = env.cursor;
        if !env.in_grouping_b(G_c, 98, 122) {
            env.limit_backward = v_11;
            break 'lab5;
        }
        env.bra = env.cursor;
        context.S_ch = env.slice_to();
        env.limit_backward = v_11;
        if !env.eq_s_b(&context.S_ch) {
            break 'lab5;
        }
        env.slice_del();
        break 'lab5;
    }
    env.cursor = env.limit - v_10;
    env.cursor = env.limit_backward;
    return true
}
