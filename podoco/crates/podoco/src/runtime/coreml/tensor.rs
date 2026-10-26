//! Scoped access only; byte copies avoid assumptions about pointer alignment.
use super::invalid;
use crate::Result;
use cidre::{ml, ns};

pub(super) struct Layout {
    shape: Vec<usize>,
    strides: Vec<usize>,
    pub(super) span: usize,
}
impl Layout {
    fn new(
        shape: &[usize],
        strides: &[i64],
        capacity: Option<usize>,
        writable: bool,
    ) -> Result<Self> {
        if shape.is_empty()
            || shape.contains(&0)
            || shape.len() != strides.len()
            || strides.iter().any(|&s| s < 0)
        {
            return Err(invalid("invalid tensor dimensions/strides"));
        }
        let strides: Vec<usize> = strides.iter().map(|&s| s as usize).collect();
        let mut elements = 1usize;
        for (&dim, &stride) in shape.iter().zip(&strides) {
            elements = elements
                .checked_add(
                    (dim - 1)
                        .checked_mul(stride)
                        .ok_or_else(|| invalid("tensor span overflow"))?,
                )
                .ok_or_else(|| invalid("tensor span overflow"))?;
        }
        let span = elements
            .checked_mul(4)
            .filter(|&n| n <= isize::MAX as usize)
            .ok_or_else(|| invalid("tensor byte span overflow"))?;
        if capacity.is_some_and(|n| n < span) {
            return Err(invalid("tensor span exceeds accessible bytes"));
        }
        if writable {
            let mut axes: Vec<_> = shape
                .iter()
                .zip(&strides)
                .filter(|(n, _)| **n > 1)
                .collect();
            axes.sort_by_key(|(_, stride)| **stride);
            let mut extent = 1usize;
            for (&dim, &stride) in axes {
                if stride < extent {
                    return Err(invalid("writable tensor has overlapping elements"));
                }
                extent += (dim - 1) * stride;
            }
        }
        Ok(Self {
            shape: shape.to_vec(),
            strides,
            span,
        })
    }
    pub(super) fn inspect(array: &ml::MultiArray, expected: &[usize]) -> Result<Self> {
        let shape = array.shape();
        if array.d_type() != ml::MultiArrayDType::F32
            || shape.len() != expected.len()
            || shape
                .iter()
                .zip(expected)
                .any(|(n, &e)| n.as_i64() != e as i64)
        {
            return Err(invalid("unexpected tensor shape or dtype"));
        }
        Self::new(expected, &numbers(&array.strides()), None, false)
    }
    fn offset(&self, mut index: usize) -> usize {
        let mut offset = 0;
        for (&dim, &stride) in self.shape.iter().zip(&self.strides).rev() {
            offset += (index % dim) * stride;
            index /= dim;
        }
        offset * 4
    }
    fn contiguous(&self) -> bool {
        let mut extent = 1;
        for (&dim, &stride) in self.shape.iter().zip(&self.strides).rev() {
            if dim > 1 && stride != extent {
                return false;
            }
            extent *= dim;
        }
        true
    }
}
fn numbers(array: &ns::Array<ns::Number>) -> Vec<i64> {
    array.iter().map(|n| n.as_i64()).collect()
}
#[cfg(test)]
pub(super) fn check_finite(array: &ml::MultiArray, shape: &[usize]) -> Result<usize> {
    let mut result = Err(invalid("mask handler did not run"));
    array.bytes(|ptr, size| {
        result = (|| {
            if ptr.is_null() || size < 0 {
                return Err(invalid("invalid mask storage"));
            }
            let layout = Layout::new(
                shape,
                &numbers(&array.strides()),
                Some(size as usize),
                false,
            )?;
            for i in 0..shape.iter().product() {
                // SAFETY: Scoped initialized F32 element, checked span; unaligned
                // reads handle arbitrary strides without touching padding.
                let value = unsafe {
                    ptr.cast::<u8>()
                        .add(layout.offset(i))
                        .cast::<f32>()
                        .read_unaligned()
                };
                if !value.is_finite() {
                    return Err(invalid("non-finite mask output"));
                }
            }
            Ok(layout.span)
        })();
    });
    result
}
pub(super) fn read(
    array: &ml::MultiArray,
    shape: &[usize],
    destination: &mut [f32],
) -> Result<usize> {
    if shape.iter().product::<usize>() != destination.len() {
        return Err(invalid("output length mismatch"));
    }
    let mut result = Err(invalid("native read handler did not run"));
    array.bytes(|ptr, size| {
        result = (|| {
            if ptr.is_null() || size < 0 {
                return Err(invalid("invalid readable storage"));
            }
            let layout = Layout::new(
                shape,
                &numbers(&array.strides()),
                Some(size as usize),
                false,
            )?;
            if layout.contiguous() {
                // SAFETY: Checked accessible span and contiguous initialized F32
                // elements; caller-owned destination never aliases native output.
                unsafe {
                    std::ptr::copy_nonoverlapping(
                        ptr.cast::<u8>(),
                        destination.as_mut_ptr().cast::<u8>(),
                        destination.len() * 4,
                    );
                }
            } else {
                for (i, value) in destination.iter_mut().enumerate() {
                    // SAFETY: Each initialized element is in the checked scoped
                    // span. Byte copies avoid alignment and uninitialized padding.
                    unsafe {
                        std::ptr::copy_nonoverlapping(
                            ptr.cast::<u8>().add(layout.offset(i)),
                            std::ptr::from_mut(value).cast::<u8>(),
                            4,
                        );
                    }
                }
            }
            Ok(layout.span)
        })();
    });
    result
}
pub(super) fn write(array: &mut ml::MultiArray, shape: &[usize], source: &[f32]) -> Result<usize> {
    if shape.iter().product::<usize>() != source.len() {
        return Err(invalid("input length mismatch"));
    }
    let mut result = Err(invalid("native write handler did not run"));
    array.bytes_mut(|ptr, size, strides| {
        result = (|| {
            if ptr.is_null() || size < 0 {
                return Err(invalid("invalid writable storage"));
            }
            let layout = Layout::new(shape, &numbers(strides), Some(size as usize), true)?;
            if layout.contiguous() {
                // SAFETY: Exclusive scoped storage covers the checked contiguous
                // layout. The independent host source is initialized and disjoint.
                unsafe {
                    std::ptr::copy_nonoverlapping(
                        source.as_ptr().cast::<u8>(),
                        ptr.cast::<u8>(),
                        source.len() * 4,
                    );
                }
            } else {
                for (i, value) in source.iter().enumerate() {
                    // SAFETY: Checked nonoverlapping writable offsets are in the
                    // scoped span; copy initialized bytes without reading padding.
                    unsafe {
                        std::ptr::copy_nonoverlapping(
                            std::ptr::from_ref(value).cast::<u8>(),
                            ptr.cast::<u8>().add(layout.offset(i)),
                            4,
                        );
                    }
                }
            }
            Ok(layout.span)
        })();
    });
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn spans_and_write_aliasing_are_checked() {
        let layout = Layout::new(&[2, 3], &[4, 1], Some(28), true).unwrap();
        assert_eq!(layout.offset(5), 24);
        assert!(Layout::new(&[2, 3], &[4, 1], Some(27), false).is_err());
        assert!(Layout::new(&[2, 3], &[0, 1], Some(12), false).is_ok());
        assert!(Layout::new(&[2, 3], &[0, 1], Some(12), true).is_err());
        assert!(Layout::new(&[2, 3], &[1, 1], None, true).is_err());
        assert!(Layout::new(&[2, 3], &[-1, 1], None, false).is_err());
        assert!(Layout::new(&[usize::MAX, 3], &[4, 1], None, false).is_err());
    }
}
