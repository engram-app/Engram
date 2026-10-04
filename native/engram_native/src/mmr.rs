//! Maximal Marginal Relevance selection, ported from `Engram.Search.MMR`.
//!
//! Float operations run in the same order as the Elixir version (sequential
//! sums from 0.0, no FMA), so the picks match it bit for bit, ties included.

/// Normalizes in place (the pool is the NIF's largest allocation; no copy).
/// None for an absent or zero vector: similarity 0.0.
fn unit(v: Option<Vec<f64>>) -> Option<Vec<f64>> {
    let mut v = v?;
    let mag = v.iter().fold(0.0, |acc, x| acc + x * x).sqrt();
    if mag == 0.0 {
        return None;
    }
    v.iter_mut().for_each(|x| *x /= mag);
    Some(v)
}

fn dot(a: &Option<Vec<f64>>, b: &Option<Vec<f64>>) -> f64 {
    match (a, b) {
        (Some(a), Some(b)) => a.iter().zip(b).fold(0.0, |acc, (x, y)| acc + x * y),
        _ => 0.0,
    }
}

/// Indices into the pool, in pick order. Each step maximises
/// `(1 - d) * rel - d * max_sim_to_picked`; the first step takes the top
/// relevance. Ties go to the earliest candidate in pool order.
pub fn select(vectors: Vec<Option<Vec<f64>>>, scores: &[f64], limit: usize, d: f64) -> Vec<usize> {
    let n = scores.len();
    let lo = scores.iter().cloned().fold(f64::INFINITY, f64::min);
    let hi = scores.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let range = hi - lo;
    let rel: Vec<f64> = scores
        .iter()
        .map(|s| if range == 0.0 { 1.0 } else { (s - lo) / range })
        .collect();
    let units: Vec<Option<Vec<f64>>> = vectors.into_iter().map(unit).collect();

    let mut max_sim = vec![f64::NEG_INFINITY; n];
    let mut alive = vec![true; n];
    let mut picked = Vec::with_capacity(limit.min(n));

    while picked.len() < limit.min(n) {
        let mut best: Option<(usize, f64)> = None;
        for i in (0..n).filter(|&i| alive[i]) {
            let score = if picked.is_empty() {
                rel[i]
            } else {
                (1.0 - d) * rel[i] - d * max_sim[i]
            };
            if best.is_none_or(|(_, b)| score > b) {
                best = Some((i, score));
            }
        }
        let (b, _) = best.expect("an alive candidate remains while picked < n");
        alive[b] = false;
        picked.push(b);
        for i in (0..n).filter(|&i| alive[i]) {
            max_sim[i] = max_sim[i].max(dot(&units[i], &units[b]));
        }
    }
    picked
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn diversity_prefers_the_dissimilar_second_pick() {
        let v = vec![
            Some(vec![1.0, 0.0]),
            Some(vec![1.0, 0.0]),
            Some(vec![0.0, 1.0]),
        ];
        assert_eq!(select(v.clone(), &[0.80, 0.79, 0.60], 2, 1.0), vec![0, 2]);
        assert_eq!(select(v.clone(), &[0.80, 0.79, 0.60], 2, 0.05), vec![0, 1]);
    }

    #[test]
    fn absent_and_zero_vectors_carry_no_penalty() {
        let v = vec![Some(vec![1.0, 0.0]), None, Some(vec![0.0, 0.0])];
        assert_eq!(select(v.clone(), &[0.9, 0.8, 0.7], 3, 1.0), vec![0, 1, 2]);
    }

    #[test]
    fn empty_pool_and_short_pool() {
        assert!(select(vec![], &[], 5, 0.5).is_empty());
        assert_eq!(select(vec![None], &[0.3], 5, 0.5), vec![0]);
    }

    #[test]
    fn equal_scores_tie_in_pool_order() {
        let v = vec![None, None, None];
        assert_eq!(select(v.clone(), &[0.5, 0.5, 0.5], 3, 0.3), vec![0, 1, 2]);
    }
}
