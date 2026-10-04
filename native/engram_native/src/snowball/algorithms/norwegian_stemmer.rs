//! Generated from norwegian.sbl by Snowball 3.1.1 - https://snowballstem.org/

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

static A_0: &'static [Among<Context>; 15] = &[
    Among("", -1, 1, None),
    Among("ind", 0, -1, None),
    Among("kk", 0, -1, None),
    Among("nk", 0, -1, None),
    Among("amm", 0, -1, None),
    Among("omm", 0, -1, None),
    Among("kap", 0, -1, None),
    Among("skap", 6, 1, None),
    Among("pp", 0, -1, None),
    Among("lt", 0, -1, None),
    Among("ast", 0, -1, None),
    Among("øst", 0, -1, None),
    Among("v", 0, -1, None),
    Among("hav", 12, 1, None),
    Among("giv", 12, 1, None),
];

static A_1: &'static [Among<Context>; 29] = &[
    Among("a", -1, 1, None),
    Among("e", -1, 1, None),
    Among("ede", 1, 1, None),
    Among("ande", 1, 1, None),
    Among("ende", 1, 1, None),
    Among("ane", 1, 1, None),
    Among("ene", 1, 1, None),
    Among("hetene", 6, 1, None),
    Among("erte", 1, 4, None),
    Among("en", -1, 1, None),
    Among("heten", 9, 1, None),
    Among("ar", -1, 1, None),
    Among("er", -1, 1, None),
    Among("heter", 12, 1, None),
    Among("s", -1, 3, None),
    Among("as", 14, 1, None),
    Among("es", 14, 1, None),
    Among("edes", 16, 1, None),
    Among("endes", 16, 1, None),
    Among("enes", 16, 1, None),
    Among("hetenes", 19, 1, None),
    Among("ens", 14, 1, None),
    Among("hetens", 21, 1, None),
    Among("ers", 14, 2, None),
    Among("ets", 14, 1, None),
    Among("et", -1, 1, None),
    Among("het", 25, 1, None),
    Among("ert", -1, 4, None),
    Among("ast", -1, 1, None),
];

static A_2: &'static [Among<Context>; 2] = &[
    Among("dt", -1, -1, None),
    Among("vt", -1, -1, None),
];

static A_3: &'static [Among<Context>; 11] = &[
    Among("leg", -1, 1, None),
    Among("eleg", 0, 1, None),
    Among("ig", -1, 1, None),
    Among("eig", 2, 1, None),
    Among("lig", 2, 1, None),
    Among("elig", 4, 1, None),
    Among("els", -1, 1, None),
    Among("lov", -1, 1, None),
    Among("elov", 7, 1, None),
    Among("slov", 7, 1, None),
    Among("hetslov", 9, 1, None),
];

static G_v: &'static [u8; 19] = &[17, 65, 16, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 48, 2, 142];

static G_s_ending: &'static [u8; 4] = &[119, 125, 148, 1];

pub fn stem(env: &mut SnowballEnv) -> bool {
    let mut context = &mut Context {
    };
    let mut among_var;
    let mut i_x : i32;
    let mut i_p1 : i32;
    let v_1 = env.cursor;
    'lab0: loop {
        i_p1 = env.limit;
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
        i_p1 = env.cursor;
        'lab1: loop {
            if i_p1 >= i_x {
                break 'lab1;
            }
            i_p1 = i_x;
            break 'lab1;
        }
        break 'lab0;
    }
    env.cursor = v_1;
    env.limit_backward = env.cursor;
    env.cursor = env.limit;
    let v_3 = env.limit - env.cursor;
    'lab2: loop {
        if env.cursor < i_p1 {
            break 'lab2;
        }
        let v_4 = env.limit_backward;
        env.limit_backward = i_p1;
        env.ket = env.cursor;
        if (env.cursor <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((1851426 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
            env.limit_backward = v_4;
            break 'lab2;
        }

        among_var = env.find_among_b(A_1, context);
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
                if (env.cursor <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((5318672 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {among_var = 1;}
                else {
                    among_var = env.find_among_b(A_0, context);
                }
                match among_var {
                    1 => {
                        env.slice_del();
                    }
                    _ => ()
                }
            }
            3 => {
                'lab3: loop {
                    let v_5 = env.limit - env.cursor;
                    'lab4: loop {
                        if !env.in_grouping_b(G_s_ending, 98, 122) {
                            break 'lab4;
                        }
                        break 'lab3;
                    }
                    env.cursor = env.limit - v_5;
                    'lab5: loop {
                        if !env.eq_s_b(&"r") {
                            break 'lab5;
                        }
                        'lab6: loop {
                            if !env.eq_s_b(&"e") {
                                break 'lab6;
                            }
                            break 'lab5;
                        }
                        break 'lab3;
                    }
                    env.cursor = env.limit - v_5;
                    if !env.eq_s_b(&"k") {
                        break 'lab2;
                    }
                    if !env.out_grouping_b(G_v, 97, 248) {
                        break 'lab2;
                    }
                    break 'lab3;
                }
                env.slice_del();
            }
            4 => {
                env.slice_from("er");
            }
            _ => ()
        }
        break 'lab2;
    }
    env.cursor = env.limit - v_3;
    let v_6 = env.limit - env.cursor;
    'lab7: loop {
        let v_7 = env.limit - env.cursor;
        if env.cursor < i_p1 {
            break 'lab7;
        }
        let v_8 = env.limit_backward;
        env.limit_backward = i_p1;
        env.ket = env.cursor;
        if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 116 as u8) {
            env.limit_backward = v_8;
            break 'lab7;
        }

        if env.find_among_b(A_2, context) == 0 {
            env.limit_backward = v_8;
            break 'lab7;
        }
        env.bra = env.cursor;
        env.limit_backward = v_8;
        env.cursor = env.limit - v_7;
        if env.cursor <= env.limit_backward {
            break 'lab7;
        }
        env.previous_char();
        env.bra = env.cursor;
        env.slice_del();
        break 'lab7;
    }
    env.cursor = env.limit - v_6;
    let v_9 = env.limit - env.cursor;
    'lab8: loop {
        if env.cursor < i_p1 {
            break 'lab8;
        }
        let v_10 = env.limit_backward;
        env.limit_backward = i_p1;
        env.ket = env.cursor;
        if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((4718720 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
            env.limit_backward = v_10;
            break 'lab8;
        }

        if env.find_among_b(A_3, context) == 0 {
            env.limit_backward = v_10;
            break 'lab8;
        }
        env.bra = env.cursor;
        env.limit_backward = v_10;
        env.slice_del();
        break 'lab8;
    }
    env.cursor = env.limit - v_9;
    env.cursor = env.limit_backward;
    return true
}
