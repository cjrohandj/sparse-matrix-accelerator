from __future__ import annotations

from manim import *


WEIGHTS = [
    [3, -1, 0, 2],
    [4, 5, -2, 1],
    [0, -7, 6, 2],
    [8, 1, -3, 4],
]

DENSE_INPUT = [
    [1, 2, 3, 4],
    [5, 6, 7, 8],
    [9, 10, 11, 12],
    [13, 14, 15, 16],
]


def prune_2_of_4(matrix):
    sparse = []
    pruned = []
    for row in matrix:
        kept = sorted(range(4), key=lambda idx: (-abs(row[idx]), idx))[:2]
        kept.sort()
        sparse.append(
            {
                "indices": kept,
                "values": [row[idx] for idx in kept],
            }
        )
        pruned.append([value if col in kept else 0 for col, value in enumerate(row)])
    return sparse, pruned


def matmul(lhs, rhs):
    return [
        [
            sum(lhs[row][inner] * rhs[inner][col] for inner in range(4))
            for col in range(4)
        ]
        for row in range(4)
    ]


SPARSE_ROWS, PRUNED_WEIGHTS = prune_2_of_4(WEIGHTS)
OUTPUT = matmul(PRUNED_WEIGHTS, DENSE_INPUT)


class SparseAcceleratorScene(Scene):
    def construct(self):
        self.camera.background_color = "#eef2f0"

        dense_group = self.matrix_group(WEIGHTS, "Initial weights A", kept=False)
        sparse_group = self.matrix_group(PRUNED_WEIGHTS, "Resultant sparse A", kept=True)
        box = self.conversion_box()

        flow = VGroup(dense_group, box, sparse_group).arrange(RIGHT, buff=0.7)
        flow.scale_to_fit_width(12.4).move_to(ORIGIN)

        self.play(FadeIn(dense_group, shift=RIGHT * 0.2))
        self.play(GrowFromCenter(box), run_time=0.7)
        kept_marks = self.kept_overlays(dense_group)
        self.play(*[Create(mark) for mark in kept_marks], run_time=0.8)
        self.play(TransformFromCopy(dense_group, sparse_group), run_time=1.0)
        self.wait(1.5)

        self.play(
            FadeOut(dense_group),
            FadeOut(box),
            sparse_group.animate.scale(0.76).to_corner(UL, buff=0.45),
            FadeOut(VGroup(*kept_marks)),
        )

        index_labels = self.sparse_index_labels(sparse_group)
        dense_input = self.matrix_group(DENSE_INPUT, "Dense input B", kept=False)
        dense_input.scale(0.72).to_edge(LEFT, buff=0.45).shift(DOWN * 1.65)
        output_matrix = self.matrix_group(OUTPUT, "Streamed output C", kept=False)
        output_matrix.scale(0.72).to_edge(RIGHT, buff=0.45).shift(DOWN * 1.65)
        unit = self.unit_diagram().move_to(ORIGIN + DOWN * 1.45)

        self.play(FadeIn(index_labels, shift=LEFT * 0.2))
        self.play(FadeIn(dense_input, shift=RIGHT * 0.2), FadeIn(output_matrix, shift=LEFT * 0.2))
        self.play(FadeIn(unit, shift=UP * 0.2))
        self.wait(1.4)

        self.animate_multiply_step(0, sparse_group, index_labels, dense_input, unit, output_matrix)
        self.wait(2.5)

    def matrix_group(self, values, label, kept):
        label_mob = Text(label, font_size=24, weight=BOLD, color="#17211d")
        cells = VGroup()
        for row in range(4):
            for col in range(4):
                value = values[row][col]
                fill = "#f8faf9"
                stroke = "#c8d2cd"
                text_color = "#17211d"
                if kept and value == 0:
                    fill = "#e6ece9"
                    text_color = "#8b9691"
                elif kept:
                    fill = "#dff5ef"
                    stroke = "#0f766e"
                square = RoundedRectangle(
                    width=0.62,
                    height=0.48,
                    corner_radius=0.05,
                    fill_color=fill,
                    fill_opacity=1,
                    stroke_color=stroke,
                    stroke_width=2,
                )
                number = Text(str(value), font_size=20, weight=BOLD, color=text_color)
                cells.add(VGroup(square, number))

        cells.arrange_in_grid(rows=4, cols=4, buff=0.08)
        cells.next_to(label_mob, DOWN, buff=0.16)
        group = VGroup(label_mob, cells)
        group.cells = cells
        return group

    def conversion_box(self):
        rect = RoundedRectangle(
            width=3.0,
            height=1.4,
            corner_radius=0.08,
            fill_color="#ffffff",
            fill_opacity=1,
            stroke_color="#0f766e",
            stroke_width=3,
        )
        title = Text("Sparse conversion", font_size=24, weight=BOLD, color="#0f5f59")
        body = Text("keep 2 of every 4", font_size=20, color="#58665f")
        return VGroup(rect, VGroup(title, body).arrange(DOWN, buff=0.12).move_to(rect))

    def kept_overlays(self, matrix_group):
        marks = []
        for row in range(4):
            for col in SPARSE_ROWS[row]["indices"]:
                cell = matrix_group.cells[row * 4 + col][0]
                marks.append(self.shape_outline(cell, "#0f766e"))
        return marks

    def sparse_index_labels(self, sparse_group):
        labels = VGroup()
        for row, encoded in enumerate(SPARSE_ROWS):
            row_cells = VGroup(*[sparse_group.cells[row * 4 + col] for col in range(4)])
            text = Text(
                f"indices {encoded['indices'][0]}, {encoded['indices'][1]}",
                font_size=16,
                weight=NORMAL,
                color="#0f5f59",
            )
            text.next_to(row_cells, RIGHT, buff=0.18)
            labels.add(text)
        labels.rows = labels
        return labels

    def unit_diagram(self):
        title = Text("Sparse multiplication unit", font_size=24, weight=BOLD, color="#17211d")
        col = self.small_register("dense column", "#f8faf9")
        mux0 = self.block("MUX[0]", "#e8f3f1", "#0f5f59")
        mux1 = self.block("MUX[3]", "#e8f3f1", "#0f5f59")
        selected0 = self.block("", "#ffffff", "#17211d", width=0.72)
        selected1 = self.block("", "#ffffff", "#17211d", width=0.72)
        times0 = Text("x", font_size=26, weight=BOLD, color="#17211d")
        times1 = Text("x", font_size=26, weight=BOLD, color="#17211d")
        mul0 = self.block("", "#fff7ed", "#8a4306")
        mul1 = self.block("", "#fff7ed", "#8a4306")
        add = self.block("+", "#f8faf9", "#17211d", width=0.9, height=1.25)
        out = self.small_register("output", "#eff6ff")

        lane0 = VGroup(mux0, selected0, times0, mul0).arrange(RIGHT, buff=0.14)
        lane1 = VGroup(mux1, selected1, times1, mul1).arrange(RIGHT, buff=0.14)
        lanes = VGroup(lane0, lane1).arrange(DOWN, buff=0.28)
        body = VGroup(col, lanes, add, out).arrange(RIGHT, buff=0.28)
        body.next_to(title, DOWN, buff=0.18)

        arrows = VGroup(
            Arrow(col.get_right(), lane0.get_left(), buff=0.08, color="#58665f"),
            Arrow(col.get_right(), lane1.get_left(), buff=0.08, color="#58665f"),
            Arrow(mul0.get_right(), add.get_left() + UP * 0.25, buff=0.08, color="#58665f"),
            Arrow(mul1.get_right(), add.get_left() + DOWN * 0.25, buff=0.08, color="#58665f"),
            Arrow(add.get_right(), out.get_left(), buff=0.08, color="#58665f"),
        )

        group = VGroup(title, body, arrows)
        group.dense_col = col
        group.mux0 = mux0
        group.mux1 = mux1
        group.selected0 = selected0
        group.selected1 = selected1
        group.mul0 = mul0
        group.mul1 = mul1
        group.add = add
        group.out = out
        return group

    def block(self, label, fill, color, width=1.25, height=0.55):
        rect = RoundedRectangle(
            width=width,
            height=height,
            corner_radius=0.06,
            fill_color=fill,
            fill_opacity=1,
            stroke_color="#c8d2cd",
        )
        text = Text(label, font_size=16, weight=BOLD, color=color)
        return VGroup(rect, text.move_to(rect))

    def small_register(self, label, fill):
        rect = RoundedRectangle(
            width=1.35,
            height=1.45,
            corner_radius=0.06,
            fill_color=fill,
            fill_opacity=1,
            stroke_color="#c8d2cd",
        )
        text = Text(label, font_size=16, weight=BOLD, color="#17211d")
        return VGroup(rect, text.move_to(rect))

    def register_contents(self, lines, font_size=20, color="#17211d"):
        return VGroup(
            *[Text(str(line), font_size=font_size, weight=BOLD, color=color) for line in lines]
        ).arrange(DOWN, buff=0.08)

    def replace_block_text(self, block, text):
        new_text = Text(str(text), font_size=22, weight=BOLD, color="#17211d").move_to(block[0])
        return Transform(block[1], new_text)

    def shape_outline(self, shape, color, stroke_width=4):
        outline = shape.copy()
        outline.set_fill(opacity=0)
        outline.set_stroke(color=color, width=stroke_width, opacity=1)
        return outline

    def block_outline(self, block, color):
        return self.shape_outline(block[0], color)

    def animate_multiply_step(self, step, sparse_group, index_labels, dense_input, unit, output_matrix):
        row = step // 4
        col = step % 4
        encoded = SPARSE_ROWS[row]
        selected_rows = encoded["indices"]
        values = encoded["values"]
        inputs = [DENSE_INPUT[input_row][col] for input_row in selected_rows]
        products = [values[lane] * inputs[lane] for lane in range(2)]
        total = sum(products)

        weight_marks = [
            self.shape_outline(sparse_group.cells[row * 4 + selected_rows[lane]][0], "#1e3a8a")
            for lane in range(2)
        ]
        input_marks = [
            self.shape_outline(dense_input.cells[selected_rows[lane] * 4 + col][0], "#1e3a8a")
            for lane in range(2)
        ]
        output_mark = self.shape_outline(output_matrix.cells[row * 4 + col][0], "#1d4ed8")

        row_index_mark = SurroundingRectangle(index_labels.rows[row], color="#1e3a8a", buff=0.06, stroke_width=3)

        dense_column_values = [DENSE_INPUT[input_row][col] for input_row in range(4)]
        dense_column_text = self.register_contents(dense_column_values).move_to(unit.dense_col[0])
        output_text = Text(str(total), font_size=30, weight=BOLD, color="#1d4ed8").move_to(unit.out[0])
        mux0_outline = self.block_outline(unit.mux0, "#1e3a8a")
        mux1_outline = self.block_outline(unit.mux1, "#1e3a8a")
        add_outline = self.block_outline(unit.add, "#1d4ed8")

        self.play(
            Create(row_index_mark),
            *[Create(mark) for mark in weight_marks],
            self.replace_block_text(unit.mul0, values[0]),
            self.replace_block_text(unit.mul1, values[1]),
            run_time=0.6,
        )
        self.wait(1.0)
        self.play(Transform(unit.dense_col[1], dense_column_text), run_time=0.6)
        self.wait(1.0)
        self.play(*[Create(mark) for mark in input_marks], run_time=0.7)
        self.wait(1.0)
        self.play(Create(mux0_outline), run_time=0.5)
        self.wait(1.0)
        self.play(self.replace_block_text(unit.selected0, inputs[0]), run_time=0.5)
        self.wait(1.0)
        self.play(Create(mux1_outline), run_time=0.5)
        self.wait(1.0)
        self.play(self.replace_block_text(unit.selected1, inputs[1]), run_time=0.5)
        self.wait(1.0)
        self.play(
            Create(add_outline),
            Transform(unit.out[1], output_text),
            run_time=0.6,
        )
        self.wait(1.0)
        self.play(Create(output_mark), run_time=0.5)
        self.wait(1.35)
        self.play(
            FadeOut(row_index_mark),
            FadeOut(VGroup(*weight_marks, *input_marks, output_mark, mux0_outline, mux1_outline, add_outline)),
            run_time=0.45,
        )
