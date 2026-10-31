"""Regenerate the tiny runtime fixture using an existing coremltools 9.0 interpreter."""
from pathlib import Path

import numpy as np
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder
from coremltools.models.utils import save_spec
from coremltools.proto import FeatureTypes_pb2

builder = NeuralNetworkBuilder(
    [("x", datatypes.Array(1, 2, 3))],
    [("y", datatypes.Array(1, 2, 3)), ("z", datatypes.Array(1, 2, 3))],
    disable_rank5_shape_mapping=True,
)
builder.add_scale(
    name="affine", W=np.array([2], dtype=np.float32),
    b=np.array([1], dtype=np.float32), has_bias=True,
    input_name="x", output_name="y", shape_scale=[1], shape_bias=[1],
)
builder.add_scale(
    name="second_affine", W=np.array([3], dtype=np.float32),
    b=np.array([-1], dtype=np.float32), has_bias=True,
    input_name="x", output_name="z", shape_scale=[1], shape_bias=[1],
)
for feature in [*builder.spec.description.input, *builder.spec.description.output]:
    feature.type.multiArrayType.dataType = FeatureTypes_pb2.ArrayFeatureType.FLOAT32
builder.spec.description.metadata.shortDescription = (
    "MLSR runtime fixture: y = 2*x + 1, z = 3*x - 1, float32 shape [1,2,3]."
)
save_spec(builder.spec, str(Path(__file__).with_name("affine.mlmodel")))
