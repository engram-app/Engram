//! Generated from finnish.sbl by Snowball 3.1.1 - https://snowballstem.org/

#![allow(non_snake_case)]
#![allow(non_upper_case_globals)]
#![allow(unused_mut)]
#![allow(unused_parens)]
#![allow(unused_variables)]
use crate::snowball::SnowballEnv;
use crate::snowball::Among;

#[derive(Clone)]
struct Context {
    S_x: String,
}

static A_0: &'static [Among<Context>; 10] = &[
    Among("pa", -1, 1, None),
    Among("sti", -1, 2, None),
    Among("kaan", -1, 1, None),
    Among("han", -1, 1, None),
    Among("kin", -1, 1, None),
    Among("hän", -1, 1, None),
    Among("kään", -1, 1, None),
    Among("ko", -1, 1, None),
    Among("pä", -1, 1, None),
    Among("kö", -1, 1, None),
];

static A_1: &'static [Among<Context>; 6] = &[
    Among("lla", -1, -1, None),
    Among("na", -1, -1, None),
    Among("ssa", -1, -1, None),
    Among("ta", -1, -1, None),
    Among("lta", 3, -1, None),
    Among("sta", 3, -1, None),
];

static A_2: &'static [Among<Context>; 6] = &[
    Among("llä", -1, -1, None),
    Among("nä", -1, -1, None),
    Among("ssä", -1, -1, None),
    Among("tä", -1, -1, None),
    Among("ltä", 3, -1, None),
    Among("stä", 3, -1, None),
];

static A_3: &'static [Among<Context>; 2] = &[
    Among("lle", -1, -1, None),
    Among("ine", -1, -1, None),
];

static A_4: &'static [Among<Context>; 9] = &[
    Among("nsa", -1, 3, None),
    Among("mme", -1, 3, None),
    Among("nne", -1, 3, None),
    Among("ni", -1, 2, None),
    Among("si", -1, 1, None),
    Among("an", -1, 4, None),
    Among("en", -1, 6, None),
    Among("än", -1, 5, None),
    Among("nsä", -1, 3, None),
];

static A_5: &'static [Among<Context>; 7] = &[
    Among("aa", -1, -1, None),
    Among("ee", -1, -1, None),
    Among("ii", -1, -1, None),
    Among("oo", -1, -1, None),
    Among("uu", -1, -1, None),
    Among("ää", -1, -1, None),
    Among("öö", -1, -1, None),
];

static A_6: &'static [Among<Context>; 30] = &[
    Among("a", -1, 8, None),
    Among("lla", 0, -1, None),
    Among("na", 0, -1, None),
    Among("ssa", 0, -1, None),
    Among("ta", 0, -1, None),
    Among("lta", 4, -1, None),
    Among("sta", 4, -1, None),
    Among("tta", 4, 2, None),
    Among("lle", -1, -1, None),
    Among("ine", -1, -1, None),
    Among("ksi", -1, -1, None),
    Among("n", -1, 7, None),
    Among("han", 11, 1, None),
    Among("den", 11, -1, Some(&r_VI)),
    Among("seen", 11, -1, Some(&r_LONG)),
    Among("hen", 11, 2, None),
    Among("tten", 11, -1, Some(&r_VI)),
    Among("hin", 11, 3, None),
    Among("siin", 11, -1, Some(&r_VI)),
    Among("hon", 11, 4, None),
    Among("hän", 11, 5, None),
    Among("hön", 11, 6, None),
    Among("ä", -1, 8, None),
    Among("llä", 22, -1, None),
    Among("nä", 22, -1, None),
    Among("ssä", 22, -1, None),
    Among("tä", 22, -1, None),
    Among("ltä", 26, -1, None),
    Among("stä", 26, -1, None),
    Among("ttä", 26, 2, None),
];

static A_7: &'static [Among<Context>; 14] = &[
    Among("eja", -1, -1, None),
    Among("mma", -1, 1, None),
    Among("imma", 1, -1, None),
    Among("mpa", -1, 1, None),
    Among("impa", 3, -1, None),
    Among("mmi", -1, 1, None),
    Among("immi", 5, -1, None),
    Among("mpi", -1, 1, None),
    Among("impi", 7, -1, None),
    Among("ejä", -1, -1, None),
    Among("mmä", -1, 1, None),
    Among("immä", 10, -1, None),
    Among("mpä", -1, 1, None),
    Among("impä", 12, -1, None),
];

static A_9: &'static [Among<Context>; 2] = &[
    Among("mma", -1, 1, None),
    Among("imma", 0, -1, None),
];

static G_AEI: &'static [u8; 17] = &[17, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8];

static G_C: &'static [u8; 4] = &[119, 223, 119, 1];

static G_V1: &'static [u8; 19] = &[17, 65, 16, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0, 32];

static G_V2: &'static [u8; 19] = &[17, 65, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0, 32];

static G_particle_end: &'static [u8; 19] = &[17, 97, 24, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0, 32];

fn r_LONG(env: &mut SnowballEnv, context: &mut Context) -> bool {
    return env.find_among_b(A_5, context) != 0;
}

fn r_VI(env: &mut SnowballEnv, context: &mut Context) -> bool {
    if !env.eq_s_b(&"i") {
        return false;
    }
    return env.in_grouping_b(G_V2, 97, 246);
}

pub fn stem(env: &mut SnowballEnv) -> bool {
    let mut context = &mut Context {
        S_x: String::new(),
    };
    let mut among_var;
    let mut b_ending_removed : bool;
    let mut i_p2 : i32;
    let mut i_p1 : i32;
    let v_1 = env.cursor;
    'lab0: loop {
        i_p1 = env.limit;
        i_p2 = env.limit;
        if !env.go_out_grouping(G_V1, 97, 246) {
            break 'lab0;
        }
        env.next_char();
        if !env.go_in_grouping(G_V1, 97, 246) {
            break 'lab0;
        }
        env.next_char();
        i_p1 = env.cursor;
        if !env.go_out_grouping(G_V1, 97, 246) {
            break 'lab0;
        }
        env.next_char();
        if !env.go_in_grouping(G_V1, 97, 246) {
            break 'lab0;
        }
        env.next_char();
        i_p2 = env.cursor;
        break 'lab0;
    }
    env.cursor = v_1;
    b_ending_removed = false;
    env.limit_backward = env.cursor;
    env.cursor = env.limit;
    let v_2 = env.limit - env.cursor;
    'lab1: loop {
        if env.cursor < i_p1 {
            break 'lab1;
        }
        let v_3 = env.limit_backward;
        env.limit_backward = i_p1;
        env.ket = env.cursor;
        among_var = env.find_among_b(A_0, context);
        if among_var == 0 {
            env.limit_backward = v_3;
            break 'lab1;
        }
        env.bra = env.cursor;
        env.limit_backward = v_3;
        match among_var {
            1 => {
                if !env.in_grouping_b(G_particle_end, 97, 246) {
                    break 'lab1;
                }
            }
            2 => {
                if i_p2 > env.cursor {
                    break 'lab1;
                }
            }
            _ => ()
        }
        env.slice_del();
        break 'lab1;
    }
    env.cursor = env.limit - v_2;
    let v_4 = env.limit - env.cursor;
    'lab2: loop {
        if env.cursor < i_p1 {
            break 'lab2;
        }
        let v_5 = env.limit_backward;
        env.limit_backward = i_p1;
        env.ket = env.cursor;
        among_var = env.find_among_b(A_4, context);
        if among_var == 0 {
            env.limit_backward = v_5;
            break 'lab2;
        }
        env.bra = env.cursor;
        env.limit_backward = v_5;
        match among_var {
            1 => {
                'lab3: loop {
                    if !env.eq_s_b(&"k") {
                        break 'lab3;
                    }
                    break 'lab2;
                }
                env.slice_del();
            }
            2 => {
                env.slice_del();
                env.ket = env.cursor;
                if !env.eq_s_b(&"kse") {
                    break 'lab2;
                }
                env.bra = env.cursor;
                env.slice_from("ksi");
            }
            3 => {
                env.slice_del();
            }
            4 => {
                if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 97 as u8) {
                    break 'lab2;
                }

                if env.find_among_b(A_1, context) == 0 {
                    break 'lab2;
                }
                env.slice_del();
            }
            5 => {
                if (env.cursor - 2 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 164 as u8) {
                    break 'lab2;
                }

                if env.find_among_b(A_2, context) == 0 {
                    break 'lab2;
                }
                env.slice_del();
            }
            6 => {
                if (env.cursor - 2 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 101 as u8) {
                    break 'lab2;
                }

                if env.find_among_b(A_3, context) == 0 {
                    break 'lab2;
                }
                env.slice_del();
            }
            _ => ()
        }
        break 'lab2;
    }
    env.cursor = env.limit - v_4;
    let v_6 = env.limit - env.cursor;
    'lab4: loop {
        if env.cursor < i_p1 {
            break 'lab4;
        }
        let v_7 = env.limit_backward;
        env.limit_backward = i_p1;
        env.ket = env.cursor;
        among_var = env.find_among_b(A_6, context);
        if among_var == 0 {
            env.limit_backward = v_7;
            break 'lab4;
        }
        env.bra = env.cursor;
        env.limit_backward = v_7;
        match among_var {
            1 => {
                if !env.eq_s_b(&"a") {
                    break 'lab4;
                }
            }
            2 => {
                if !env.eq_s_b(&"e") {
                    break 'lab4;
                }
            }
            3 => {
                if !env.eq_s_b(&"i") {
                    break 'lab4;
                }
            }
            4 => {
                if !env.eq_s_b(&"o") {
                    break 'lab4;
                }
            }
            5 => {
                if !env.eq_s_b(&"ä") {
                    break 'lab4;
                }
            }
            6 => {
                if !env.eq_s_b(&"ö") {
                    break 'lab4;
                }
            }
            7 => {
                let v_8 = env.limit - env.cursor;
                'lab5: loop {
                    let v_9 = env.limit - env.cursor;
                    'lab6: loop {
                        let v_10 = env.limit - env.cursor;
                        'lab7: loop {
                            if !r_LONG(env, context) {
                                break 'lab7;
                            }
                            break 'lab6;
                        }
                        env.cursor = env.limit - v_10;
                        if !env.eq_s_b(&"ie") {
                            env.cursor = env.limit - v_8;
                            break 'lab5;
                        }
                        break 'lab6;
                    }
                    env.cursor = env.limit - v_9;
                    if env.cursor <= env.limit_backward {
                        env.cursor = env.limit - v_8;
                        break 'lab5;
                    }
                    env.previous_char();
                    env.bra = env.cursor;
                    break 'lab5;
                }
            }
            8 => {
                if !env.in_grouping_b(G_V1, 97, 246) {
                    break 'lab4;
                }
                if !env.in_grouping_b(G_C, 98, 122) {
                    break 'lab4;
                }
            }
            _ => ()
        }
        env.slice_del();
        b_ending_removed = true;
        break 'lab4;
    }
    env.cursor = env.limit - v_6;
    let v_11 = env.limit - env.cursor;
    'lab8: loop {
        if env.cursor < i_p2 {
            break 'lab8;
        }
        let v_12 = env.limit_backward;
        env.limit_backward = i_p2;
        env.ket = env.cursor;
        among_var = env.find_among_b(A_7, context);
        if among_var == 0 {
            env.limit_backward = v_12;
            break 'lab8;
        }
        env.bra = env.cursor;
        env.limit_backward = v_12;
        match among_var {
            1 => {
                'lab9: loop {
                    if !env.eq_s_b(&"po") {
                        break 'lab9;
                    }
                    break 'lab8;
                }
            }
            _ => ()
        }
        env.slice_del();
        break 'lab8;
    }
    env.cursor = env.limit - v_11;
    'lab10: loop {
        'lab11: loop {
            if !b_ending_removed {
                break 'lab11;
            }
            let v_13 = env.limit - env.cursor;
            'lab12: loop {
                if env.cursor < i_p1 {
                    break 'lab12;
                }
                let v_14 = env.limit_backward;
                env.limit_backward = i_p1;
                env.ket = env.cursor;
                if (env.cursor <= env.limit_backward || (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 105 as u8 && env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 106 as u8)) {
                    env.limit_backward = v_14;
                    break 'lab12;
                }

                env.cursor -= 1;
                env.bra = env.cursor;
                env.limit_backward = v_14;
                env.slice_del();
                break 'lab12;
            }
            env.cursor = env.limit - v_13;
            break 'lab10;
        }
        let v_15 = env.limit - env.cursor;
        'lab13: loop {
            if env.cursor < i_p1 {
                break 'lab13;
            }
            let v_16 = env.limit_backward;
            env.limit_backward = i_p1;
            env.ket = env.cursor;
            if !env.eq_s_b(&"t") {
                env.limit_backward = v_16;
                break 'lab13;
            }
            env.bra = env.cursor;
            let v_17 = env.limit - env.cursor;
            if !env.in_grouping_b(G_V1, 97, 246) {
                env.limit_backward = v_16;
                break 'lab13;
            }
            env.cursor = env.limit - v_17;
            env.slice_del();
            env.limit_backward = v_16;
            if env.cursor < i_p2 {
                break 'lab13;
            }
            let v_18 = env.limit_backward;
            env.limit_backward = i_p2;
            env.ket = env.cursor;
            if (env.cursor - 2 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 != 97 as u8) {
                env.limit_backward = v_18;
                break 'lab13;
            }

            among_var = env.find_among_b(A_9, context);
            if among_var == 0 {
                env.limit_backward = v_18;
                break 'lab13;
            }
            env.bra = env.cursor;
            env.limit_backward = v_18;
            match among_var {
                1 => {
                    'lab14: loop {
                        if !env.eq_s_b(&"po") {
                            break 'lab14;
                        }
                        break 'lab13;
                    }
                }
                _ => ()
            }
            env.slice_del();
            break 'lab13;
        }
        env.cursor = env.limit - v_15;
        break 'lab10;
    }
    let v_19 = env.limit - env.cursor;
    'lab15: loop {
        if env.cursor < i_p1 {
            break 'lab15;
        }
        let v_20 = env.limit_backward;
        env.limit_backward = i_p1;
        let v_21 = env.limit - env.cursor;
        'lab16: loop {
            let v_22 = env.limit - env.cursor;
            if !r_LONG(env, context) {
                break 'lab16;
            }
            env.cursor = env.limit - v_22;
            env.ket = env.cursor;
            if env.cursor <= env.limit_backward {
                break 'lab16;
            }
            env.previous_char();
            env.bra = env.cursor;
            env.slice_del();
            break 'lab16;
        }
        env.cursor = env.limit - v_21;
        let v_23 = env.limit - env.cursor;
        'lab17: loop {
            env.ket = env.cursor;
            if !env.in_grouping_b(G_AEI, 97, 228) {
                break 'lab17;
            }
            env.bra = env.cursor;
            if !env.in_grouping_b(G_C, 98, 122) {
                break 'lab17;
            }
            env.slice_del();
            break 'lab17;
        }
        env.cursor = env.limit - v_23;
        let v_24 = env.limit - env.cursor;
        'lab18: loop {
            env.ket = env.cursor;
            if !env.eq_s_b(&"j") {
                break 'lab18;
            }
            env.bra = env.cursor;
            'lab19: loop {
                'lab20: loop {
                    if !env.eq_s_b(&"o") {
                        break 'lab20;
                    }
                    break 'lab19;
                }
                if !env.eq_s_b(&"u") {
                    break 'lab18;
                }
                break 'lab19;
            }
            env.slice_del();
            break 'lab18;
        }
        env.cursor = env.limit - v_24;
        let v_25 = env.limit - env.cursor;
        'lab21: loop {
            env.ket = env.cursor;
            if !env.eq_s_b(&"o") {
                break 'lab21;
            }
            env.bra = env.cursor;
            if !env.eq_s_b(&"j") {
                break 'lab21;
            }
            env.slice_del();
            break 'lab21;
        }
        env.cursor = env.limit - v_25;
        env.limit_backward = v_20;
        if !env.go_in_grouping_b(G_V1, 97, 246) {
            break 'lab15;
        }
        env.ket = env.cursor;
        if !env.in_grouping_b(G_C, 98, 122) {
            break 'lab15;
        }
        env.bra = env.cursor;
        context.S_x = env.slice_to();
        if !env.eq_s_b(&context.S_x) {
            break 'lab15;
        }
        env.slice_del();
        break 'lab15;
    }
    env.cursor = env.limit - v_19;
    env.cursor = env.limit_backward;
    return true
}
