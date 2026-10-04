//! Generated from indonesian.sbl by Snowball 3.1.1 - https://snowballstem.org/

#![allow(non_snake_case)]
#![allow(non_upper_case_globals)]
#![allow(unused_mut)]
#![allow(unused_parens)]
#![allow(unused_variables)]
use crate::snowball::SnowballEnv;
use crate::snowball::Among;

#[derive(Clone)]
struct Context {
    i_prefix: i32,
    i_measure: i32,
}

static A_0: &'static [Among<Context>; 3] = &[
    Among("kah", -1, 1, None),
    Among("lah", -1, 1, None),
    Among("pun", -1, 1, None),
];

static A_1: &'static [Among<Context>; 3] = &[
    Among("nya", -1, 1, None),
    Among("ku", -1, 1, None),
    Among("mu", -1, 1, None),
];

static A_2: &'static [Among<Context>; 2] = &[
    Among("i", -1, 2, None),
    Among("an", -1, 1, None),
];

static A_3: &'static [Among<Context>; 10] = &[
    Among("di", -1, 1, None),
    Among("ke", -1, 3, None),
    Among("me", -1, 1, None),
    Among("mem", 2, 5, None),
    Among("men", 2, 2, None),
    Among("meng", 4, 1, None),
    Among("pem", -1, 6, None),
    Among("pen", -1, 4, None),
    Among("peng", 7, 3, None),
    Among("ter", -1, 1, None),
];

static A_4: &'static [Among<Context>; 2] = &[
    Among("be", -1, 2, None),
    Among("pe", -1, 1, None),
];

static G_vowel: &'static [u8; 3] = &[17, 65, 16];

fn r_remove_suffix(env: &mut SnowballEnv, context: &mut Context) -> bool {
    let mut among_var;
    env.ket = env.cursor;
    if (env.cursor <= env.limit_backward || (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 105 as u8 && env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 110 as u8)) {
        return false;
    }

    among_var = env.find_among_b(A_2, context);
    if among_var == 0 {
        return false;
    }
    env.bra = env.cursor;
    match among_var {
        1 => {
            'lab0: loop {
                let v_1 = env.limit - env.cursor;
                'lab1: loop {
                    if context.i_prefix == 3 {
                        break 'lab1;
                    }
                    if context.i_prefix == 2 {
                        break 'lab1;
                    }
                    if !env.eq_s_b(&"k") {
                        break 'lab1;
                    }
                    env.bra = env.cursor;
                    break 'lab0;
                }
                env.cursor = env.limit - v_1;
                if context.i_prefix == 1 {
                    return false;
                }
                break 'lab0;
            }
        }
        2 => {
            if context.i_prefix > 2 {
                return false;
            }
            'lab2: loop {
                if !env.eq_s_b(&"s") {
                    break 'lab2;
                }
                return false;
            }
        }
        _ => ()
    }
    env.slice_del();
    context.i_measure -= 1;
    return true
}

fn r_remove_second_order_prefix(env: &mut SnowballEnv, context: &mut Context) -> bool {
    let mut among_var;
    env.bra = env.cursor;
    if (env.cursor + 1 >= env.limit || env.current.as_bytes()[(env.cursor + 1) as usize] as u8 != 101 as u8) {
        return false;
    }

    among_var = env.find_among(A_4, context);
    if among_var == 0 {
        return false;
    }
    match among_var {
        1 => {
            'lab0: loop {
                let v_1 = env.cursor;
                'lab1: loop {
                    if !env.eq_s(&"r") {
                        break 'lab1;
                    }
                    env.ket = env.cursor;
                    context.i_prefix = 2;
                    break 'lab0;
                }
                env.cursor = v_1;
                'lab2: loop {
                    if !env.eq_s(&"l") {
                        break 'lab2;
                    }
                    env.ket = env.cursor;
                    if !env.eq_s(&"ajar") {
                        break 'lab2;
                    }
                    break 'lab0;
                }
                env.cursor = v_1;
                env.ket = env.cursor;
                context.i_prefix = 2;
                break 'lab0;
            }
        }
        2 => {
            'lab3: loop {
                let v_2 = env.cursor;
                'lab4: loop {
                    if !env.eq_s(&"r") {
                        break 'lab4;
                    }
                    env.ket = env.cursor;
                    break 'lab3;
                }
                env.cursor = v_2;
                'lab5: loop {
                    if !env.eq_s(&"l") {
                        break 'lab5;
                    }
                    env.ket = env.cursor;
                    if !env.eq_s(&"ajar") {
                        break 'lab5;
                    }
                    break 'lab3;
                }
                env.cursor = v_2;
                env.ket = env.cursor;
                if !env.out_grouping(G_vowel, 97, 117) {
                    return false;
                }
                if !env.eq_s(&"er") {
                    return false;
                }
                break 'lab3;
            }
            context.i_prefix = 4;
        }
        _ => ()
    }
    context.i_measure -= 1;
    env.slice_del();
    return true
}

pub fn stem(env: &mut SnowballEnv) -> bool {
    let mut context = &mut Context {
        i_prefix: 0,
        i_measure: 0,
    };
    let mut among_var;
    context.i_measure = 0;
    let v_1 = env.cursor;
    'lab0: loop {
        'replab1: loop{
            let v_2 = env.cursor;
            'lab2: for _ in 0..1 {
                if !env.go_out_grouping(G_vowel, 97, 117) {
                    break 'lab2;
                }
                env.next_char();
                context.i_measure += 1;
                continue 'replab1;
            }
            env.cursor = v_2;
            break 'replab1;
        }
        break 'lab0;
    }
    env.cursor = v_1;
    if context.i_measure < 3 {
        return false;
    }
    context.i_prefix = 0;
    env.limit_backward = env.cursor;
    env.cursor = env.limit;
    let v_3 = env.limit - env.cursor;
    'lab3: loop {
        env.ket = env.cursor;
        if (env.cursor - 2 <= env.limit_backward || (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 104 as u8 && env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 110 as u8)) {
            break 'lab3;
        }

        if env.find_among_b(A_0, context) == 0 {
            break 'lab3;
        }
        env.bra = env.cursor;
        env.slice_del();
        context.i_measure -= 1;
        break 'lab3;
    }
    env.cursor = env.limit - v_3;
    if context.i_measure < 3 {
        return false;
    }
    let v_4 = env.limit - env.cursor;
    'lab4: loop {
        env.ket = env.cursor;
        if (env.cursor - 1 <= env.limit_backward || (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 97 as u8 && env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 117 as u8)) {
            break 'lab4;
        }

        if env.find_among_b(A_1, context) == 0 {
            break 'lab4;
        }
        env.bra = env.cursor;
        env.slice_del();
        context.i_measure -= 1;
        break 'lab4;
    }
    env.cursor = env.limit - v_4;
    env.cursor = env.limit_backward;
    if context.i_measure < 3 {
        return false;
    }
    'lab5: loop {
        let v_5 = env.cursor;
        'lab6: loop {
            let v_6 = env.cursor;
            env.bra = env.cursor;
            if (env.cursor + 1 >= env.limit || (env.current.as_bytes()[(env.cursor + 1) as usize] as u8 != 105 as u8 && env.current.as_bytes()[(env.cursor + 1) as usize] as u8 != 101 as u8)) {
                break 'lab6;
            }

            among_var = env.find_among(A_3, context);
            if among_var == 0 {
                break 'lab6;
            }
            env.ket = env.cursor;
            match among_var {
                1 => {
                    env.slice_del();
                    context.i_prefix = 1;
                    context.i_measure -= 1;
                }
                2 => {
                    'lab7: loop {
                        let v_7 = env.cursor;
                        'lab8: loop {
                            if !env.eq_s(&"y") {
                                break 'lab8;
                            }
                            let v_8 = env.cursor;
                            if !env.in_grouping(G_vowel, 97, 117) {
                                break 'lab8;
                            }
                            env.cursor = v_8;
                            env.ket = env.cursor;
                            env.slice_from("s");
                            context.i_prefix = 1;
                            context.i_measure -= 1;
                            break 'lab7;
                        }
                        env.cursor = v_7;
                        env.slice_del();
                        context.i_prefix = 1;
                        context.i_measure -= 1;
                        break 'lab7;
                    }
                }
                3 => {
                    env.slice_del();
                    context.i_prefix = 3;
                    context.i_measure -= 1;
                }
                4 => {
                    'lab9: loop {
                        let v_9 = env.cursor;
                        'lab10: loop {
                            if !env.eq_s(&"y") {
                                break 'lab10;
                            }
                            let v_10 = env.cursor;
                            if !env.in_grouping(G_vowel, 97, 117) {
                                break 'lab10;
                            }
                            env.cursor = v_10;
                            env.ket = env.cursor;
                            env.slice_from("s");
                            context.i_prefix = 3;
                            context.i_measure -= 1;
                            break 'lab9;
                        }
                        env.cursor = v_9;
                        env.slice_del();
                        context.i_prefix = 3;
                        context.i_measure -= 1;
                        break 'lab9;
                    }
                }
                5 => {
                    context.i_prefix = 1;
                    context.i_measure -= 1;
                    'lab11: loop {
                        let v_11 = env.cursor;
                        'lab12: loop {
                            let v_12 = env.cursor;
                            if !env.in_grouping(G_vowel, 97, 117) {
                                break 'lab12;
                            }
                            env.cursor = v_12;
                            env.slice_from("p");
                            break 'lab11;
                        }
                        env.cursor = v_11;
                        env.slice_del();
                        break 'lab11;
                    }
                }
                6 => {
                    context.i_prefix = 3;
                    context.i_measure -= 1;
                    'lab13: loop {
                        let v_13 = env.cursor;
                        'lab14: loop {
                            let v_14 = env.cursor;
                            if !env.in_grouping(G_vowel, 97, 117) {
                                break 'lab14;
                            }
                            env.cursor = v_14;
                            env.slice_from("p");
                            break 'lab13;
                        }
                        env.cursor = v_13;
                        env.slice_del();
                        break 'lab13;
                    }
                }
                _ => ()
            }
            let v_15 = env.cursor;
            'lab15: loop {
                let v_16 = env.cursor;
                if context.i_measure < 3 {
                    break 'lab15;
                }
                env.limit_backward = env.cursor;
                env.cursor = env.limit;
                if !r_remove_suffix(env, context) {
                    break 'lab15;
                }
                env.cursor = env.limit_backward;
                env.cursor = v_16;
                if context.i_measure < 3 {
                    break 'lab15;
                }
                if !r_remove_second_order_prefix(env, context) {
                    break 'lab15;
                }
                break 'lab15;
            }
            env.cursor = v_15;
            env.cursor = v_6;
            break 'lab5;
        }
        env.cursor = v_5;
        let v_17 = env.cursor;
        r_remove_second_order_prefix(env, context);
        env.cursor = v_17;
        let v_18 = env.cursor;
        'lab16: loop {
            if context.i_measure < 3 {
                break 'lab16;
            }
            env.limit_backward = env.cursor;
            env.cursor = env.limit;
            if !r_remove_suffix(env, context) {
                break 'lab16;
            }
            env.cursor = env.limit_backward;
            break 'lab16;
        }
        env.cursor = v_18;
        break 'lab5;
    }
    return true
}
