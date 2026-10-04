//! Generated from romanian.sbl by Snowball 3.1.1 - https://snowballstem.org/

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

static A_0: &'static [Among<Context>; 2] = &[
    Among("ş", -1, 1, None),
    Among("ţ", -1, 2, None),
];

static A_1: &'static [Among<Context>; 3] = &[
    Among("", -1, 3, None),
    Among("I", 0, 1, None),
    Among("U", 0, 2, None),
];

static A_2: &'static [Among<Context>; 16] = &[
    Among("ea", -1, 3, None),
    Among("ația", -1, 7, None),
    Among("aua", -1, 2, None),
    Among("iua", -1, 4, None),
    Among("ație", -1, 7, None),
    Among("ele", -1, 3, None),
    Among("ile", -1, 5, None),
    Among("iile", 6, 4, None),
    Among("iei", -1, 4, None),
    Among("atei", -1, 6, None),
    Among("ii", -1, 4, None),
    Among("ului", -1, 1, None),
    Among("ul", -1, 1, None),
    Among("elor", -1, 3, None),
    Among("ilor", -1, 4, None),
    Among("iilor", 14, 4, None),
];

static A_3: &'static [Among<Context>; 46] = &[
    Among("icala", -1, 4, None),
    Among("iciva", -1, 4, None),
    Among("ativa", -1, 5, None),
    Among("itiva", -1, 6, None),
    Among("icale", -1, 4, None),
    Among("ațiune", -1, 5, None),
    Among("ițiune", -1, 6, None),
    Among("atoare", -1, 5, None),
    Among("itoare", -1, 6, None),
    Among("ătoare", -1, 5, None),
    Among("icitate", -1, 4, None),
    Among("abilitate", -1, 1, None),
    Among("ibilitate", -1, 2, None),
    Among("ivitate", -1, 3, None),
    Among("icive", -1, 4, None),
    Among("ative", -1, 5, None),
    Among("itive", -1, 6, None),
    Among("icali", -1, 4, None),
    Among("atori", -1, 5, None),
    Among("icatori", 18, 4, None),
    Among("itori", -1, 6, None),
    Among("ători", -1, 5, None),
    Among("icitati", -1, 4, None),
    Among("abilitati", -1, 1, None),
    Among("ivitati", -1, 3, None),
    Among("icivi", -1, 4, None),
    Among("ativi", -1, 5, None),
    Among("itivi", -1, 6, None),
    Among("icităi", -1, 4, None),
    Among("abilităi", -1, 1, None),
    Among("ivităi", -1, 3, None),
    Among("icități", -1, 4, None),
    Among("abilități", -1, 1, None),
    Among("ivități", -1, 3, None),
    Among("ical", -1, 4, None),
    Among("ator", -1, 5, None),
    Among("icator", 35, 4, None),
    Among("itor", -1, 6, None),
    Among("ător", -1, 5, None),
    Among("iciv", -1, 4, None),
    Among("ativ", -1, 5, None),
    Among("itiv", -1, 6, None),
    Among("icală", -1, 4, None),
    Among("icivă", -1, 4, None),
    Among("ativă", -1, 5, None),
    Among("itivă", -1, 6, None),
];

static A_4: &'static [Among<Context>; 62] = &[
    Among("ica", -1, 1, None),
    Among("abila", -1, 1, None),
    Among("ibila", -1, 1, None),
    Among("oasa", -1, 1, None),
    Among("ata", -1, 1, None),
    Among("ita", -1, 1, None),
    Among("anta", -1, 1, None),
    Among("ista", -1, 3, None),
    Among("uta", -1, 1, None),
    Among("iva", -1, 1, None),
    Among("ic", -1, 1, None),
    Among("ice", -1, 1, None),
    Among("abile", -1, 1, None),
    Among("ibile", -1, 1, None),
    Among("isme", -1, 3, None),
    Among("iune", -1, 2, None),
    Among("oase", -1, 1, None),
    Among("ate", -1, 1, None),
    Among("itate", 17, 1, None),
    Among("ite", -1, 1, None),
    Among("ante", -1, 1, None),
    Among("iste", -1, 3, None),
    Among("ute", -1, 1, None),
    Among("ive", -1, 1, None),
    Among("ici", -1, 1, None),
    Among("abili", -1, 1, None),
    Among("ibili", -1, 1, None),
    Among("iuni", -1, 2, None),
    Among("atori", -1, 1, None),
    Among("osi", -1, 1, None),
    Among("ati", -1, 1, None),
    Among("itati", 30, 1, None),
    Among("iti", -1, 1, None),
    Among("anti", -1, 1, None),
    Among("isti", -1, 3, None),
    Among("uti", -1, 1, None),
    Among("iști", -1, 3, None),
    Among("ivi", -1, 1, None),
    Among("ităi", -1, 1, None),
    Among("oși", -1, 1, None),
    Among("ități", -1, 1, None),
    Among("abil", -1, 1, None),
    Among("ibil", -1, 1, None),
    Among("ism", -1, 3, None),
    Among("ator", -1, 1, None),
    Among("os", -1, 1, None),
    Among("at", -1, 1, None),
    Among("it", -1, 1, None),
    Among("ant", -1, 1, None),
    Among("ist", -1, 3, None),
    Among("ut", -1, 1, None),
    Among("iv", -1, 1, None),
    Among("ică", -1, 1, None),
    Among("abilă", -1, 1, None),
    Among("ibilă", -1, 1, None),
    Among("oasă", -1, 1, None),
    Among("ată", -1, 1, None),
    Among("ită", -1, 1, None),
    Among("antă", -1, 1, None),
    Among("istă", -1, 3, None),
    Among("ută", -1, 1, None),
    Among("ivă", -1, 1, None),
];

static A_5: &'static [Among<Context>; 94] = &[
    Among("ea", -1, 1, None),
    Among("ia", -1, 1, None),
    Among("esc", -1, 1, None),
    Among("ăsc", -1, 1, None),
    Among("ind", -1, 1, None),
    Among("ând", -1, 1, None),
    Among("are", -1, 1, None),
    Among("ere", -1, 1, None),
    Among("ire", -1, 1, None),
    Among("âre", -1, 1, None),
    Among("se", -1, 2, None),
    Among("ase", 10, 1, None),
    Among("sese", 10, 2, None),
    Among("ise", 10, 1, None),
    Among("use", 10, 1, None),
    Among("âse", 10, 1, None),
    Among("ește", -1, 1, None),
    Among("ăște", -1, 1, None),
    Among("eze", -1, 1, None),
    Among("ai", -1, 1, None),
    Among("eai", 19, 1, None),
    Among("iai", 19, 1, None),
    Among("sei", -1, 2, None),
    Among("ești", -1, 1, None),
    Among("ăști", -1, 1, None),
    Among("ui", -1, 1, None),
    Among("ezi", -1, 1, None),
    Among("ași", -1, 1, None),
    Among("seși", -1, 2, None),
    Among("aseși", 28, 1, None),
    Among("seseși", 28, 2, None),
    Among("iseși", 28, 1, None),
    Among("useși", 28, 1, None),
    Among("âseși", 28, 1, None),
    Among("iși", -1, 1, None),
    Among("uși", -1, 1, None),
    Among("âși", -1, 1, None),
    Among("ați", -1, 2, None),
    Among("eați", 37, 1, None),
    Among("iați", 37, 1, None),
    Among("eți", -1, 2, None),
    Among("iți", -1, 2, None),
    Among("arăți", -1, 1, None),
    Among("serăți", -1, 2, None),
    Among("aserăți", 43, 1, None),
    Among("seserăți", 43, 2, None),
    Among("iserăți", 43, 1, None),
    Among("userăți", 43, 1, None),
    Among("âserăți", 43, 1, None),
    Among("irăți", -1, 1, None),
    Among("urăți", -1, 1, None),
    Among("ârăți", -1, 1, None),
    Among("âți", -1, 2, None),
    Among("âi", -1, 1, None),
    Among("am", -1, 1, None),
    Among("eam", 54, 1, None),
    Among("iam", 54, 1, None),
    Among("em", -1, 2, None),
    Among("asem", 57, 1, None),
    Among("sesem", 57, 2, None),
    Among("isem", 57, 1, None),
    Among("usem", 57, 1, None),
    Among("âsem", 57, 1, None),
    Among("im", -1, 2, None),
    Among("ăm", -1, 2, None),
    Among("arăm", 64, 1, None),
    Among("serăm", 64, 2, None),
    Among("aserăm", 66, 1, None),
    Among("seserăm", 66, 2, None),
    Among("iserăm", 66, 1, None),
    Among("userăm", 66, 1, None),
    Among("âserăm", 66, 1, None),
    Among("irăm", 64, 1, None),
    Among("urăm", 64, 1, None),
    Among("ârăm", 64, 1, None),
    Among("âm", -1, 2, None),
    Among("au", -1, 1, None),
    Among("eau", 76, 1, None),
    Among("iau", 76, 1, None),
    Among("indu", -1, 1, None),
    Among("ându", -1, 1, None),
    Among("ez", -1, 1, None),
    Among("ească", -1, 1, None),
    Among("ară", -1, 1, None),
    Among("seră", -1, 2, None),
    Among("aseră", 84, 1, None),
    Among("seseră", 84, 2, None),
    Among("iseră", 84, 1, None),
    Among("useră", 84, 1, None),
    Among("âseră", 84, 1, None),
    Among("iră", -1, 1, None),
    Among("ură", -1, 1, None),
    Among("âră", -1, 1, None),
    Among("ează", -1, 1, None),
];

static A_6: &'static [Among<Context>; 5] = &[
    Among("a", -1, 1, None),
    Among("e", -1, 1, None),
    Among("ie", 1, 1, None),
    Among("i", -1, 1, None),
    Among("ă", -1, 1, None),
];

static G_v: &'static [u8; 21] = &[17, 65, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 32, 0, 0, 4];

pub fn stem(env: &mut SnowballEnv) -> bool {
    let mut context = &mut Context {
    };
    let mut among_var;
    let mut b_standard_suffix_removed : bool;
    let mut i_p2 : i32;
    let mut i_p1 : i32;
    let mut i_pV : i32;
    'lab0: loop {
        let v_1 = env.cursor;
        'lab1: loop {
            'replab2: loop{
                let v_2 = env.cursor;
                'lab3: for _ in 0..1 {
                    'golab4: loop {
                        let v_3 = env.cursor;
                        'lab5: loop {
                            env.bra = env.cursor;
                            if (env.cursor + 1 >= env.limit || (env.current.as_bytes()[(env.cursor + 1) as usize] as u8 != 159 as u8 && env.current.as_bytes()[(env.cursor + 1) as usize] as u8 != 163 as u8)) {
                                break 'lab5;
                            }

                            among_var = env.find_among(A_0, context);
                            if among_var == 0 {
                                break 'lab5;
                            }
                            env.ket = env.cursor;
                            match among_var {
                                1 => {
                                    env.slice_from("ș");
                                }
                                2 => {
                                    env.slice_from("ț");
                                }
                                _ => ()
                            }
                            env.cursor = v_3;
                            break 'golab4;
                        }
                        env.cursor = v_3;
                        if env.cursor >= env.limit {
                            break 'lab3;
                        }
                        env.next_char();
                    }
                    continue 'replab2;
                }
                env.cursor = v_2;
                break 'replab2;
            }
            break 'lab1;
        }
        env.cursor = v_1;
        break 'lab0;
    }
    let v_4 = env.cursor;
    'lab6: loop {
        'replab7: loop{
            let v_5 = env.cursor;
            'lab8: for _ in 0..1 {
                'golab9: loop {
                    let v_6 = env.cursor;
                    'lab10: loop {
                        if !env.in_grouping(G_v, 97, 259) {
                            break 'lab10;
                        }
                        env.bra = env.cursor;
                        'lab11: loop {
                            let v_7 = env.cursor;
                            'lab12: loop {
                                if !env.eq_s(&"u") {
                                    break 'lab12;
                                }
                                env.ket = env.cursor;
                                if !env.in_grouping(G_v, 97, 259) {
                                    break 'lab12;
                                }
                                env.slice_from("U");
                                break 'lab11;
                            }
                            env.cursor = v_7;
                            if !env.eq_s(&"i") {
                                break 'lab10;
                            }
                            env.ket = env.cursor;
                            if !env.in_grouping(G_v, 97, 259) {
                                break 'lab10;
                            }
                            env.slice_from("I");
                            break 'lab11;
                        }
                        env.cursor = v_6;
                        break 'golab9;
                    }
                    env.cursor = v_6;
                    if env.cursor >= env.limit {
                        break 'lab8;
                    }
                    env.next_char();
                }
                continue 'replab7;
            }
            env.cursor = v_5;
            break 'replab7;
        }
        break 'lab6;
    }
    env.cursor = v_4;
    'lab13: loop {
        i_pV = env.limit;
        i_p1 = env.limit;
        i_p2 = env.limit;
        let v_8 = env.cursor;
        'lab14: loop {
            'lab15: loop {
                let v_9 = env.cursor;
                'lab16: loop {
                    if !env.in_grouping(G_v, 97, 259) {
                        break 'lab16;
                    }
                    'lab17: loop {
                        let v_10 = env.cursor;
                        'lab18: loop {
                            if !env.out_grouping(G_v, 97, 259) {
                                break 'lab18;
                            }
                            if !env.go_out_grouping(G_v, 97, 259) {
                                break 'lab18;
                            }
                            env.next_char();
                            break 'lab17;
                        }
                        env.cursor = v_10;
                        if !env.in_grouping(G_v, 97, 259) {
                            break 'lab16;
                        }
                        if !env.go_in_grouping(G_v, 97, 259) {
                            break 'lab16;
                        }
                        env.next_char();
                        break 'lab17;
                    }
                    break 'lab15;
                }
                env.cursor = v_9;
                if !env.out_grouping(G_v, 97, 259) {
                    break 'lab14;
                }
                'lab19: loop {
                    let v_11 = env.cursor;
                    'lab20: loop {
                        if !env.out_grouping(G_v, 97, 259) {
                            break 'lab20;
                        }
                        if !env.go_out_grouping(G_v, 97, 259) {
                            break 'lab20;
                        }
                        env.next_char();
                        break 'lab19;
                    }
                    env.cursor = v_11;
                    if !env.in_grouping(G_v, 97, 259) {
                        break 'lab14;
                    }
                    if env.cursor >= env.limit {
                        break 'lab14;
                    }
                    env.next_char();
                    break 'lab19;
                }
                break 'lab15;
            }
            i_pV = env.cursor;
            break 'lab14;
        }
        env.cursor = v_8;
        let v_12 = env.cursor;
        'lab21: loop {
            if !env.go_out_grouping(G_v, 97, 259) {
                break 'lab21;
            }
            env.next_char();
            if !env.go_in_grouping(G_v, 97, 259) {
                break 'lab21;
            }
            env.next_char();
            i_p1 = env.cursor;
            if !env.go_out_grouping(G_v, 97, 259) {
                break 'lab21;
            }
            env.next_char();
            if !env.go_in_grouping(G_v, 97, 259) {
                break 'lab21;
            }
            env.next_char();
            i_p2 = env.cursor;
            break 'lab21;
        }
        env.cursor = v_12;
        break 'lab13;
    }
    env.limit_backward = env.cursor;
    env.cursor = env.limit;
    let v_13 = env.limit - env.cursor;
    'lab22: loop {
        env.ket = env.cursor;
        if (env.cursor - 1 <= env.limit_backward || env.current.as_bytes()[(env.cursor - 1) as usize] as u8 >> 5 != 3 as u8 || ((266786 as i32 >> (env.current.as_bytes()[(env.cursor - 1) as usize] as u8 & 0x1f)) & 1) == 0) {
            break 'lab22;
        }

        among_var = env.find_among_b(A_2, context);
        if among_var == 0 {
            break 'lab22;
        }
        env.bra = env.cursor;
        if i_p1 > env.cursor {
            break 'lab22;
        }
        match among_var {
            1 => {
                env.slice_del();
            }
            2 => {
                env.slice_from("a");
            }
            3 => {
                env.slice_from("e");
            }
            4 => {
                env.slice_from("i");
            }
            5 => {
                'lab23: loop {
                    if !env.eq_s_b(&"ab") {
                        break 'lab23;
                    }
                    break 'lab22;
                }
                env.slice_from("i");
            }
            6 => {
                env.slice_from("at");
            }
            7 => {
                env.slice_from("ați");
            }
            _ => ()
        }
        break 'lab22;
    }
    env.cursor = env.limit - v_13;
    let v_14 = env.limit - env.cursor;
    'lab24: loop {
        b_standard_suffix_removed = false;
        'replab25: loop{
            let v_15 = env.limit - env.cursor;
            'lab26: for _ in 0..1 {
                let v_16 = env.limit - env.cursor;
                env.ket = env.cursor;
                among_var = env.find_among_b(A_3, context);
                if among_var == 0 {
                    break 'lab26;
                }
                env.bra = env.cursor;
                if i_p1 > env.cursor {
                    break 'lab26;
                }
                match among_var {
                    1 => {
                        env.slice_from("abil");
                    }
                    2 => {
                        env.slice_from("ibil");
                    }
                    3 => {
                        env.slice_from("iv");
                    }
                    4 => {
                        env.slice_from("ic");
                    }
                    5 => {
                        env.slice_from("at");
                    }
                    6 => {
                        env.slice_from("it");
                    }
                    _ => ()
                }
                b_standard_suffix_removed = true;
                env.cursor = env.limit - v_16;
                continue 'replab25;
            }
            env.cursor = env.limit - v_15;
            break 'replab25;
        }
        env.ket = env.cursor;
        among_var = env.find_among_b(A_4, context);
        if among_var == 0 {
            break 'lab24;
        }
        env.bra = env.cursor;
        if i_p2 > env.cursor {
            break 'lab24;
        }
        match among_var {
            1 => {
                env.slice_del();
            }
            2 => {
                if !env.eq_s_b(&"ț") {
                    break 'lab24;
                }
                env.bra = env.cursor;
                env.slice_from("t");
            }
            3 => {
                env.slice_from("ist");
            }
            _ => ()
        }
        b_standard_suffix_removed = true;
        break 'lab24;
    }
    env.cursor = env.limit - v_14;
    let v_17 = env.limit - env.cursor;
    'lab27: loop {
        'lab28: loop {
            'lab29: loop {
                if !b_standard_suffix_removed {
                    break 'lab29;
                }
                break 'lab28;
            }
            if env.cursor < i_pV {
                break 'lab27;
            }
            let v_18 = env.limit_backward;
            env.limit_backward = i_pV;
            env.ket = env.cursor;
            among_var = env.find_among_b(A_5, context);
            if among_var == 0 {
                env.limit_backward = v_18;
                break 'lab27;
            }
            env.bra = env.cursor;
            match among_var {
                1 => {
                    'lab30: loop {
                        'lab31: loop {
                            if !env.out_grouping_b(G_v, 97, 259) {
                                break 'lab31;
                            }
                            break 'lab30;
                        }
                        if !env.eq_s_b(&"u") {
                            env.limit_backward = v_18;
                            break 'lab27;
                        }
                        break 'lab30;
                    }
                    env.slice_del();
                }
                2 => {
                    env.slice_del();
                }
                _ => ()
            }
            env.limit_backward = v_18;
            break 'lab28;
        }
        break 'lab27;
    }
    env.cursor = env.limit - v_17;
    let v_19 = env.limit - env.cursor;
    'lab32: loop {
        env.ket = env.cursor;
        if env.find_among_b(A_6, context) == 0 {
            break 'lab32;
        }
        env.bra = env.cursor;
        if i_pV > env.cursor {
            break 'lab32;
        }
        env.slice_del();
        break 'lab32;
    }
    env.cursor = env.limit - v_19;
    env.cursor = env.limit_backward;
    let v_20 = env.cursor;
    'lab33: loop {
        'replab34: loop{
            let v_21 = env.cursor;
            'lab35: for _ in 0..1 {
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
                            break 'lab35;
                        }
                        env.next_char();
                    }
                    _ => ()
                }
                continue 'replab34;
            }
            env.cursor = v_21;
            break 'replab34;
        }
        break 'lab33;
    }
    env.cursor = v_20;
    return true
}
